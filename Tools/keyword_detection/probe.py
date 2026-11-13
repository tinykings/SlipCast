#!/usr/bin/env python3
"""Experimental audio keyword detection, independent of Apple's transcript.

Install requirements.txt in a virtual environment (tested with Python 3.9).
For speaker separation, install requirements-separation.txt instead.
--separate downloads the pinned separator weights on its first run.

Example, using the public SmartLess download from the investigation:
  python probe.py episode.mp3 --start 1517 --duration 30 --keyword fucking \
    --model-dir /tmp/slipcast-kws --download-model \
    --expect-window 1532 1535 --output direct.json
  python probe.py episode.mp3 --start 1517 --duration 30 --keyword fucking \
    --model-dir /tmp/slipcast-kws --separate \
    --expect-window 1532 1535 --output separated.json

Other checks: --start 3399 --duration 12 --expect-window 3404 3406 (clear
speech); --start 1940 --duration 40 --expect-absent (negative control).
Ad insertion can shift these times in another download. Verify the dialogue.

This first prototype supports English single words. With --separate it checks
both the original mixture and isolated voices. Require agreement in at least
two overlapping 1.28-second scan windows to reduce isolated false detections.
Short windows also avoid sherpa-onnx 2.0.1's timestamp resets after silence.

Exit 1 means an expectation failed. JSON retains corroborated detections from
each separation window and voice, including duplicates. Token times are approximate
onsets, NOT verified word boundaries suitable for muting playback.
This tool does not change the iPhone app or its saved transcripts.
--expect-window requires both a detection inside the window and no detections
outside the expected windows. Repeat it to require multiple known events.
For the confirmed two-event passage, test --keyword fuck with
--expect-window 1532 1535 --expect-window 1541 1543. The user identified
"fucking" in the interruption and "fuck" after the later "so funny" line.
"""

import argparse
import hashlib
import itertools
import importlib.metadata
import json
import math
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.request
from pathlib import Path

import numpy as np
import sentencepiece
import sherpa_onnx
import soundfile
from scipy.signal import resample_poly


MODEL_NAME = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
MODEL_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/"
    + MODEL_NAME + ".tar.bz2"
)
MODEL_SHA256 = "f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a"
SEPARATOR = "speechbrain/sepformer-wsj02mix"
SEPARATOR_REVISION = "3a2826343a10e2d2e8a75f79aeab5ff3a2473531"


def ensure_model(directory, download):
    """Download the official archive only when explicitly requested."""
    model = directory / MODEL_NAME
    if (model / "bpe.model").is_file():
        return model
    if not download:
        raise ValueError("Model is missing. Add --download-model for the initial setup.")
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=directory) as temporary:
        archive = Path(temporary) / "model.tar.bz2"
        with urllib.request.urlopen(MODEL_URL, timeout=120) as response:
            with archive.open("wb") as output:
                shutil.copyfileobj(response, output)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != MODEL_SHA256:
            raise ValueError("Model archive checksum differs from the tested version.")
        root = Path(temporary).resolve()
        with tarfile.open(archive) as contents:
            for member in contents.getmembers():
                target = (root / member.name).resolve()
                if root not in target.parents or not (member.isfile() or member.isdir()):
                    raise ValueError("Unsafe model archive entry: " + member.name)
            contents.extractall(root)
        # A failed previous setup may have left an incomplete directory.
        if model.exists():
            raise ValueError("Incomplete model directory exists; choose a new --model-dir.")
        shutil.move(str(root / MODEL_NAME), str(model))
    return model


def resample(samples, source_rate, target_rate):
    divisor = math.gcd(source_rate, target_rate)
    return resample_poly(samples, target_rate // divisor, source_rate // divisor).astype(np.float32)


def read_excerpt(path, start, duration):
    with soundfile.SoundFile(path) as audio:
        if start >= len(audio) / audio.samplerate:
            raise ValueError("Start time is past the end of the file.")
        audio.seek(round(start * audio.samplerate))
        samples = audio.read(round(duration * audio.samplerate), dtype="float32", always_2d=True)
        if not len(samples):
            raise ValueError("The excerpt contains no audio frames.")
        return samples.mean(axis=1), audio.samplerate


def create_detector(model, keywords_file, quantized, threshold, score):
    suffix = ".int8.onnx" if quantized else ".onnx"
    stem = "-epoch-12-avg-2-chunk-16-left-64"
    for filename in ["tokens.txt"] + [name + stem + suffix for name in ["encoder", "decoder", "joiner"]]:
        if not (model / filename).is_file():
            raise ValueError("Missing model file: " + str(model / filename))
    return sherpa_onnx.KeywordSpotter(
        tokens=str(model / "tokens.txt"),
        encoder=str(model / ("encoder" + stem + suffix)),
        decoder=str(model / ("decoder" + stem + suffix)),
        joiner=str(model / ("joiner" + stem + suffix)),
        keywords_file=str(keywords_file), num_threads=2,
        keywords_threshold=threshold, keywords_score=score,
    )


def detect(detector, samples, sample_rate, aliases, origin, window, voice, min_support):
    # In the pinned version, resetting after a detection (including the automatic
    # reset after 1.5 seconds of blanks) resets decoder timestamps. The Python
    # result cannot expose enough state to restore their origin reliably.
    # Use a fresh stream shorter than that reset interval and take its FIRST hit.
    # See v2.0.1/sherpa-onnx/csrc/keyword-spotter-transducer-impl.h, InitOnlineStream.
    candidates = []
    for offset in range(0, len(samples), round(0.32 * sample_rate)):
        stream = detector.create_stream()
        stream.accept_waveform(sample_rate, samples[offset:offset + round(1.28 * sample_rate)])
        stream.accept_waveform(sample_rate, np.zeros(round(0.66 * sample_rate), dtype=np.float32))
        stream.input_finished()
        while detector.is_ready(stream):
            detector.decode_stream(stream)
            result = detector.keyword_spotter.get_result(stream)
            if result.keyword:
                onsets = [origin + offset / sample_rate + t for t in result.timestamps]
                if onsets and origin <= min(onsets) <= origin + len(samples) / sample_rate:
                    candidates.append({
                        "keyword": aliases[result.keyword.strip()], "token_onsets": onsets,
                        "scan_start": origin + offset / sample_rate,
                    })
                break

    # Only corroborate detections within this same voice and separation window.
    # Do not turn one detection duplicated across voices into two votes.
    groups = []
    for hit in sorted(candidates, key=lambda h: min(h["token_onsets"])):
        for group in groups:
            first = group[0]
            if (first["keyword"] == hit["keyword"]
                    and abs(min(first["token_onsets"]) - min(hit["token_onsets"])) <= 0.2):
                group.append(hit)
                break
        else:
            groups.append([hit])
    hits = []
    for group in groups:
        if len(group) < min_support:
            continue
        times = [h["token_onsets"] for h in group]
        median = np.median(times, axis=0).tolist() if len({len(t) for t in times}) == 1 else times[0]
        hits.append({
            "keyword": group[0]["keyword"], "token_onsets": median,
            "supporting_scans": len(group), "scan_starts": [h["scan_start"] for h in group],
            "window_start": origin, "window": window, "voice": voice,
        })
    return hits


def separated_inputs(samples, sample_rate, cache):
    # These optional dependencies are intentionally outside the app and base probe.
    import torch
    from speechbrain.inference.separation import SepformerSeparation

    torch.set_num_threads(4)
    model = SepformerSeparation.from_hparams(
        source=SEPARATOR, revision=SEPARATOR_REVISION,
        savedir=str(cache), run_opts={"device": "cpu"},
    )
    waveform = torch.from_numpy(resample(samples, sample_rate, 8000)).unsqueeze(0)
    for window, offset in enumerate(range(0, waveform.shape[1], 5 * 8000)):
        excerpt = waveform[:, offset:offset + 15 * 8000]
        with torch.inference_mode():
            sources = model.separate_batch(excerpt)
        for voice in range(sources.shape[-1]):
            isolated = sources[0, :, voice].cpu().numpy()
            peak = float(np.max(np.abs(isolated)))
            if peak > 1e-8:
                # Consistent with the isolated-voice experiment, without clipping.
                isolated = isolated * (0.9 / peak)
            yield isolated.astype(np.float32), 8000, offset / 8000, window, voice
        if offset + excerpt.shape[1] >= waveform.shape[1]:
            break


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("--start", type=float, default=0)
    parser.add_argument("--duration", type=float, default=30)
    parser.add_argument("--keyword", action="append", required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--download-model", action="store_true")
    parser.add_argument("--quantized", action="store_true")
    parser.add_argument("--threshold", type=float, default=0.25)
    parser.add_argument("--score", type=float, default=1)
    parser.add_argument("--min-support", type=int, default=2)
    parser.add_argument("--separate", action="store_true")
    parser.add_argument("--separator-cache", type=Path)
    expectations = parser.add_mutually_exclusive_group()
    expectations.add_argument("--expect-window", type=float, nargs=2, action="append")
    expectations.add_argument("--expect-absent", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not (math.isfinite(args.start) and args.start >= 0
            and math.isfinite(args.duration) and 0 < args.duration <= 120
            and math.isfinite(args.threshold) and 0 < args.threshold <= 1
            and math.isfinite(args.score) and args.score > 0 and args.min_support >= 1):
        parser.error("Use a nonnegative start, duration of 0–120 seconds, threshold of 0–1, and positive score.")
    for lower, upper in args.expect_window or []:
        if not (math.isfinite(lower) and math.isfinite(upper)
                and args.start <= lower < upper <= args.start + args.duration):
            parser.error("Each expected window must be an increasing interval inside the excerpt.")
    keywords = list(dict.fromkeys(" ".join(word.split()).lower() for word in args.keyword))
    if any(not word or not word.isascii() or len(word.split()) != 1 for word in keywords):
        parser.error("This English prototype supports nonempty ASCII single words.")
    if importlib.metadata.version("sherpa-onnx") != "2.0.1":
        parser.error("Install the pinned sherpa-onnx 2.0.1; timestamp handling depends on this version.")

    model = ensure_model(args.model_dir.resolve(), args.download_model)
    tokenizer = sentencepiece.SentencePieceProcessor(model_file=str(model / "bpe.model"))
    aliases = {"keyword_" + str(i): word for i, word in enumerate(keywords)}
    samples, rate = read_excerpt(args.audio, args.start, args.duration)
    started = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix="slipcast-kws-") as temporary:
        keywords_file = Path(temporary) / "keywords.txt"
        lines = []
        for alias, keyword in aliases.items():
            token_ids = tokenizer.encode(keyword.upper(), out_type=int)
            pieces = [tokenizer.id_to_piece(token) for token in token_ids]
            if tokenizer.unk_id() in token_ids:
                raise ValueError("The model cannot encode keyword: " + keyword)
            lines.append(" ".join(pieces) + " @" + alias)
        keywords_file.write_text("\n".join(lines) + "\n")
        detector = create_detector(model, keywords_file, args.quantized, args.threshold, args.score)
        if args.separate:
            cache = args.separator_cache or args.model_dir / ("sepformer-" + SEPARATOR_REVISION)
            inputs = itertools.chain(
                [(samples, rate, 0, 0, "mixture")],
                separated_inputs(samples, rate, cache),
            )
        else:
            inputs = [(samples, rate, 0, 0, "mixture")]
        hits = []
        for audio, sample_rate, offset, window, voice in inputs:
            hits.extend(detect(detector, audio, sample_rate, aliases,
                               args.start + offset, window, voice, args.min_support))

    matching = hits
    windows_found = []
    if args.expect_window:
        matching = []
        for lower, upper in args.expect_window:
            found = [h for h in hits if h["token_onsets"]
                     and lower <= min(h["token_onsets"]) <= upper]
            windows_found.append(bool(found))
            matching.extend(h for h in found if h not in matching)
    extra = [h for h in hits if h not in matching] if args.expect_window else []
    if args.expect_absent:
        passed = not hits
    elif args.expect_window:
        passed = all(windows_found) and not extra
    else:
        passed = None
    report = {
        "experimental": True, "audio": str(args.audio.resolve()),
        "probe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "start": args.start, "duration": len(samples) / rate, "keywords": keywords,
        "model": MODEL_NAME, "model_archive_sha256": MODEL_SHA256,
        "quantized": args.quantized, "threshold": args.threshold, "score": args.score,
        "min_support": args.min_support, "scan_seconds": 1.28, "scan_hop_seconds": 0.32,
        "separator": SEPARATOR if args.separate else None,
        "separator_revision": SEPARATOR_REVISION if args.separate else None,
        "elapsed_seconds": time.perf_counter() - started,
        "hits": hits, "expected_windows": args.expect_window,
        "expected_windows_found": windows_found,
        "expect_absent": args.expect_absent, "expectation_passed": passed,
        "target_found": all(windows_found) if args.expect_window else None,
        "extra_hits": extra,
        "timing_note": "Approximate token onsets only; word end boundaries are not established.",
    }
    serialized = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(serialized)
    print(serialized, end="")
    return 1 if passed is False else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, ImportError) as error:
        print("Keyword probe: " + str(error), file=sys.stderr)
        sys.exit(2)

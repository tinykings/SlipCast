#!/usr/bin/env python3
"""Rebuild the bundled on-device detector resources on a Mac.

Install requirements-coreml.txt, then run this script from the repository root.
The first run downloads the pinned models. No Python runtime is used by the app.
The synthetic control is generated with macOS's Samantha voice.
"""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import coremltools as ct
import sentencepiece
import soundfile
import torch
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from speechbrain.inference.separation import SepformerSeparation

from probe import ensure_model, SEPARATOR, SEPARATOR_REVISION


@register_torch_op
def alias(context, node):
    # aten::alias is an identity op emitted by torch 2.8's attention implementation.
    context.add(context[node.inputs[0]], node.name)


class Separator(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.encoder = model.mods.encoder
        self.mask = model.mods.masknet
        self.decoder = model.mods.decoder

    def forward(self, waveform):
        encoded = self.encoder(waveform)
        separated = encoded.unsqueeze(0) * self.mask(encoded)
        return torch.stack([self.decoder(separated[i]) for i in range(2)], dim=-1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=Path.home() / "Library/Caches/SlipCastModelExport")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] / "Packages/AudioDetection/Sources/AudioDetection/Resources")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    model_path = ensure_model(args.cache.resolve(), download=True)
    for part in ["encoder", "decoder", "joiner"]:
        source = model_path / (part + "-epoch-12-avg-2-chunk-16-left-64.int8.onnx")
        shutil.copy2(source, args.output / ("keyword-" + part + ".onnx"))
    shutil.copy2(model_path / "tokens.txt", args.output / "keyword-tokens.txt")
    tokenizer = sentencepiece.SentencePieceProcessor(model_file=str(model_path / "bpe.model"))
    vocabulary = {tokenizer.id_to_piece(i): tokenizer.get_score(i) for i in range(tokenizer.get_piece_size())}
    (args.output / "keyword-vocabulary.json").write_text(json.dumps(vocabulary))

    torch.set_num_threads(4)
    model = SepformerSeparation.from_hparams(
        source=SEPARATOR, revision=SEPARATOR_REVISION,
        savedir=str(args.cache / "separator"), run_opts={"device": "cpu"},
    )
    network = Separator(model).eval()
    with torch.inference_mode():
        traced = torch.jit.trace(network, torch.zeros((1, 120_000)), check_trace=False)
    converted = ct.convert(
        traced,
        inputs=[ct.TensorType(name="waveform", shape=(1, 120_000))],
        outputs=[ct.TensorType(name="voices")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
    )
    converted.author = "SpeechBrain; SlipCast conversion"
    converted.short_description = "Two-voice speech separation at 8 kHz, fixed 15-second input."
    converted.license = "Apache-2.0; source speechbrain/sepformer-wsj02mix"
    converted.save(str(args.output / "VoiceSeparator.mlpackage"))

    control_text = (
        "We were just talking about a funny story. I would have been on the floor laughing. "
        "The funky music was coming from the hall. We were walking past the kitchen. "
        "I remember Dana and I were wondering what happened. "
        "The forking road took us toward the forest."
    )
    with tempfile.TemporaryDirectory() as folder:
        source = Path(folder) / "control.aiff"
        subprocess.run(["say", "-v", "Samantha", "-r", "165", "-o", str(source), control_text], check=True)
        samples, rate = soundfile.read(source)
        soundfile.write(args.output / "DetectionControl.wav", samples, rate)
    print("Exported native model resources to", args.output)


if __name__ == "__main__":
    main()

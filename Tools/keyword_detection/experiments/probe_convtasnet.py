import sys,pathlib,time,json
sys.path.insert(0,'/Users/ryan/dev/Podcast/Tools/keyword_detection')
import numpy as np,torch,torchaudio,sherpa_onnx
from probe import read_excerpt,resample,detect
root=pathlib.Path('/tmp/slipcast-overlap')
resources=pathlib.Path('/Users/ryan/dev/Podcast/Packages/AudioDetection/Sources/AudioDetection/Resources')
torch.set_num_threads(4);torch.hub.set_dir(str(root/'conv-tasnet'))
model=torchaudio.pipelines.CONVTASNET_BASE_LIBRI2MIX.get_model().eval()
kw=root/'small-separator-keywords.txt';kw.write_text('▁F U CK @target\n')
spotter=sherpa_onnx.KeywordSpotter(tokens=str(resources/'keyword-tokens.txt'),encoder=str(resources/'keyword-encoder.onnx'),decoder=str(resources/'keyword-decoder.onnx'),joiner=str(resources/'keyword-joiner.onnx'),keywords_file=str(kw),num_threads=2,keywords_threshold=.25,keywords_score=1,num_trailing_blanks=1)
results=[]
for start in [1527,1520,1532]:
 a,sr=read_excerpt(root/'episode.mp3',start,15);a=resample(a,sr,8000)
 began=time.monotonic()
 with torch.inference_mode():out=model(torch.from_numpy(a)[None,None,:])[0].numpy()
 elapsed=time.monotonic()-began
 hits=[]
 for voice,samples in enumerate(out):
  peak=np.max(np.abs(samples))
  if peak>1e-8:samples=samples*(.9/peak)
  hits+=detect(spotter,samples.astype('float32'),8000,{'target':'fuck'},start,0,voice,2)
 row={'start':start,'separation_elapsed':elapsed,'total_elapsed':time.monotonic()-began,'hits':hits}
 print(json.dumps(row),flush=True);results.append(row)
(root/'small-separator-results.json').write_text(json.dumps(results,indent=2))

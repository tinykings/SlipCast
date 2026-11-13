import pathlib,time,json,math
import numpy as np, soundfile as sf, onnxruntime as ort
from scipy.signal import resample_poly
model=next(pathlib.Path('/tmp/slipcast-overlap/overlap-model').rglob('model.onnx'))
options=ort.SessionOptions();options.intra_op_num_threads=2;options.inter_op_num_threads=1
session=ort.InferenceSession(str(model),sess_options=options,providers=['CPUExecutionProvider'])
def read(start,duration):
 with sf.SoundFile('/tmp/slipcast-overlap/episode.mp3') as f:
  sr=f.samplerate;f.seek(round(start*sr));a=f.read(round(duration*sr),dtype='float32',always_2d=True).mean(axis=1)
 g=math.gcd(sr,16000);return resample_poly(a,16000//g,sr//g).astype('float32')
results=[]
for origin,duration,label in [(1517,30,'known_overlap'),(1940,40,'other_speech'),(3399,12,'clear_swear')]:
 audio=read(origin,duration);began=time.monotonic();frames=[]
 for offset in range(0,max(1,len(audio)-160000+1),40000):
  chunk=audio[offset:offset+160000];chunk=np.pad(chunk,(0,160000-len(chunk)))
  y=session.run(None,{'x':chunk[None,None,:]})[0][0]
  p=np.exp(y);overlap=p[:,4:].sum(axis=1)
  for i,v in enumerate(overlap):
   t=origin+(offset+495.5+i*270)/16000
   if t<origin+duration:frames.append((t,float(v)))
 targets=[]
 for t in [1533.48,1543.6]:
  near=[v for s,v in frames if abs(t-s)<.3]
  if near:targets.append({'time':t,'max_overlap_score':max(near),'mean_overlap_score':sum(near)/len(near)})
 row={'label':label,'duration':duration,'elapsed':time.monotonic()-began,'targets':targets,'frames':frames}
 results.append(row)
 print(label,'elapsed',round(row['elapsed'],3),'targets',targets,flush=True)
pathlib.Path('/tmp/slipcast-overlap/overlap-gate-probe.json').write_text(json.dumps(results))

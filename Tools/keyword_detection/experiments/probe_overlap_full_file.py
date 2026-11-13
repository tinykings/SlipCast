import pathlib,time,json,math,hashlib
import numpy as np,soundfile as sf,onnxruntime as ort
from scipy.signal import resample_poly
root=pathlib.Path('/tmp/slipcast-overlap')
model=next((root/'overlap-model').rglob('model.onnx'))
opts=ort.SessionOptions();opts.intra_op_num_threads=2;opts.inter_op_num_threads=1
session=ort.InferenceSession(str(model),sess_options=opts,providers=['CPUExecutionProvider'])
began=time.monotonic()
with sf.SoundFile(root/'episode.mp3') as file:
 rate=file.samplerate;duration=len(file)/rate
 bins=np.zeros(int(math.ceil(duration*10)),dtype=np.float32)
 starts=np.arange(0,max(0,duration-10)+2.5,2.5)
 for n,start in enumerate(starts):
  file.seek(min(len(file),round(start*rate)))
  a=file.read(min(round(10*rate),len(file)-file.tell()),dtype='float32',always_2d=True).mean(axis=1)
  g=math.gcd(rate,16000);a=resample_poly(a,16000//g,rate//g).astype('float32')
  a=np.pad(a[:160000],(0,max(0,160000-len(a))))
  y=session.run(None,{'x':a[None,None,:]})[0][0]
  p=np.exp(y);score=p[:,4:].sum(axis=1)
  if n==0:print('probability sum',p.sum(axis=1).min(),p.sum(axis=1).max(),flush=True)
  indices=np.floor((start+(495.5+np.arange(len(score))*270)/16000)*10).astype('int64')
  keep=(indices>=0)&(indices<len(bins));np.maximum.at(bins,indices[keep],score[keep])
  if n%200==0:print('window',n,'of',len(starts),'elapsed',round(time.monotonic()-began,1),flush=True)
thresholds=[]
windows=max(1,int(math.ceil(duration-15))+1)
for threshold in [.03,.1,.25,.5]:
 active=bins>=threshold
 cumulative=np.concatenate(([0],np.cumsum(active,dtype='int64')))
 retained=[]
 for i in range(windows):
  retained.append(cumulative[min(len(bins),(i+15)*10)]>cumulative[min(len(bins),i*10)])
 thresholds.append({'threshold':threshold,'flagged_seconds':float(np.sum(active)/10),'dense_windows_retained':int(sum(retained)),'total_dense_windows':windows,'retained_fraction':float(np.mean(retained)),'known_overlap_included':bool(np.max(bins[int(1533.2*10):int(1533.9*10)])>=threshold)})
result={'duration':duration,'elapsed_seconds':time.monotonic()-began,'model_sha256':hashlib.sha256(model.read_bytes()).hexdigest(),'model_bytes':model.stat().st_size,'hop_seconds':2.5,'cpu_threads':2,'thresholds':thresholds,'phone_tested':False}
(root/'full-overlap-gate-results.json').write_text(json.dumps(result,indent=2))
np.save(root/'full-overlap-gate-scores.npy',bins)
print(json.dumps(result,indent=2),flush=True)

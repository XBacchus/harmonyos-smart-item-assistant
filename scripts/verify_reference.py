"""Independent desktop check of the same image/letterbox and YOLO output contract."""
import hashlib
import json
from pathlib import Path
import cv2
import numpy as np
import onnxruntime as ort

ROOT=Path(__file__).resolve().parents[1]
picture=ROOT/'SmartItemAssistant/entry/src/main/resources/rawfile/demo-bus.jpg'
rgb=cv2.cvtColor(cv2.imread(str(picture)),cv2.COLOR_BGR2RGB)
h,w=rgb.shape[:2]
r=min(640/w,640/h);sw,sh=round(w*r),round(h*r);left,top=(640-sw)//2,(640-sh)//2
xs=np.clip((np.arange(sw)+.5)*w/sw-.5,0,w-1);ys=np.clip((np.arange(sh)+.5)*h/sh-.5,0,h-1)
x0=xs.astype(int);y0=ys.astype(int);x1=np.minimum(x0+1,w-1);y1=np.minimum(y0+1,h-1)
fx=(xs-x0)[None,:,None];fy=(ys-y0)[:,None,None]
upper=rgb[y0[:,None],x0]*(1-fx)+rgb[y0[:,None],x1]*fx
lower=rgb[y1[:,None],x0]*(1-fx)+rgb[y1[:,None],x1]*fx
canvas=np.full((640,640,3),114/255,dtype=np.float32)
canvas[top:top+sh,left:left+sw]=(upper*(1-fy)+lower*fy)/255
session=ort.InferenceSession(str(ROOT/'models/yolov13n.onnx'),providers=['CPUExecutionProvider'])
output=session.run(None,{'images':canvas.transpose(2,0,1)[None]})[0][0]
ids=output[4:].argmax(axis=0);scores=output[4:].max(axis=0)
candidates=[]
for i in np.flatnonzero(scores>=.25):
    x,y,bw,bh=output[:4,i]
    candidates.append({'classId':int(ids[i]),'confidence':float(scores[i]),'x1':max(0,float(x-bw/2-left)*w/sw),'y1':max(0,float(y-bh/2-top)*h/sh),'x2':min(w,float(x+bw/2-left)*w/sw),'y2':min(h,float(y+bh/2-top)*h/sh)})
kept=[]
def iou(a,b):
    intersect=max(0,min(a['x2'],b['x2'])-max(a['x1'],b['x1']))*max(0,min(a['y2'],b['y2'])-max(a['y1'],b['y1']))
    area=lambda d:(d['x2']-d['x1'])*(d['y2']-d['y1'])
    return intersect/(area(a)+area(b)-intersect)
for item in sorted(candidates,key=lambda d:-d['confidence']):
    if not any(item['classId']==d['classId'] and iou(item,d)>.45 for d in kept):kept.append(item)
assert sorted(d['classId'] for d in kept)==[0,0,0,0,5]
result={'imageSha256':hashlib.sha256(picture.read_bytes()).hexdigest(),'runtime':ort.__version__,'detections':kept}
device_file=ROOT/'doc/evidence/device-result.json'
if device_file.exists():
    device=json.loads(device_file.read_text('utf-8-sig'))
    assert len(device['detections'])==len(kept)
    comparisons=[]
    for a,b in zip(kept,device['detections']):
        assert a['classId']==b['classId']
        assert iou(a,b)>.98
        assert abs(a['confidence']-b['confidence'])<.03
        comparisons.append({'classId':a['classId'],'iou':iou(a,b),'scoreDifference':abs(a['confidence']-b['confidence'])})
    result['deviceComparison']=comparisons
(ROOT/'doc/evidence/desktop-reference.json').write_text(json.dumps(result,indent=2),'utf-8')
print(json.dumps(result,indent=2))

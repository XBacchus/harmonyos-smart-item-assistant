"""Export the unmodified official YOLOv13 nano checkpoint to static ONNX."""
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
os.environ['YOLO_CONFIG_DIR'] = str(ROOT / '.work' / 'yolo-config')
os.environ['YOLO_AUTOINSTALL'] = 'false'
sys.path.insert(0, str(ROOT / '.work' / 'yolov13-upstream'))
import numpy as np
import onnx
import onnxruntime as ort
import torch
from ultralytics import YOLO

checkpoint = ROOT / 'models' / 'yolov13n.pt'
assert hashlib.sha256(checkpoint.read_bytes()).hexdigest() == '6653035017b0f111f80ec11ed914874ea85699b104aeac1e46e517d16889d6b7'
torch.set_num_threads(4)
model = YOLO(str(checkpoint))
output = Path(model.export(format='onnx', imgsz=640, opset=17, simplify=False, dynamic=False, half=False, batch=1, device='cpu', nms=False))
onnx.checker.check_model(str(output))
session = ort.InferenceSession(str(output), providers=['CPUExecutionProvider'])
rng = np.random.default_rng(42)
sample = rng.random((1, 3, 640, 640), dtype=np.float32)
actual = session.run(None, {session.get_inputs()[0].name: sample})[0]
with torch.no_grad():
    reference = model.model(torch.from_numpy(sample))
    if isinstance(reference, (list, tuple)):
        reference = reference[0]
    expected = reference.numpy()
error = float(np.max(np.abs(actual - expected)))
assert actual.shape == (1, 84, 8400), actual.shape
assert np.allclose(actual, expected, rtol=0.002, atol=0.02), error
manifest = {
    'version': 'yolov13n-coco-v1', 'source': 'https://github.com/iMoonLab/yolov13',
    'commit': '73289949533efac82bb5f72ec19b746618656bd2',
    'checkpointSha256': hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
    'sha256': hashlib.sha256(output.read_bytes()).hexdigest(), 'size': output.stat().st_size,
    'opset': 17, 'inputName': session.get_inputs()[0].name,
    'inputShape': session.get_inputs()[0].shape, 'outputName': session.get_outputs()[0].name,
    'outputShape': list(actual.shape), 'labels': list(model.names.values()),
    'referenceMaxAbsoluteError': error, 'license': 'AGPL-3.0',
    'export': {'imgsz':640,'opset':17,'simplify':False,'dynamic':False,'half':False,'nms':False},
}
(ROOT / 'models' / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({k:v for k,v in manifest.items() if k != 'labels'}, indent=2))

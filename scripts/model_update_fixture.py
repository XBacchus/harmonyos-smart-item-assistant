"""Publish a local acceptance fixture, preserving the original manifest byte for byte."""
import argparse
import json
from pathlib import Path

root=Path(__file__).resolve().parents[1]
manifest=root/'models/manifest.json'
backup=root/'.work/manifest-before-update-test.json'
parser=argparse.ArgumentParser()
parser.add_argument('mode',choices=['valid','invalid','restore'])
args=parser.parse_args()
if args.mode=='restore':
    manifest.write_bytes(backup.read_bytes())
    print('Original model manifest restored')
else:
    backup.parent.mkdir(parents=True, exist_ok=True)
    if not backup.exists():backup.write_bytes(manifest.read_bytes())
    data=json.loads(backup.read_text('utf-8'))
    data['version']='yolov13n-coco-acceptance-'+args.mode
    if args.mode=='invalid':data['sha256']='0'*64
    manifest.write_text(json.dumps(data,ensure_ascii=False,indent=2),'utf-8')
    print('Published local acceptance fixture:',data['version'],'(same model bytes)')

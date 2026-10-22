"""Explicit local provisioning. Secrets are written to ignored files, never stdout."""
import argparse
import hashlib
import json
import secrets
from pathlib import Path
from uuid import UUID, uuid4


def provision(data: Path, device_id: str | None = None):
    data.mkdir(parents=True,exist_ok=True)
    path=data/'secrets.json'
    config=json.loads(path.read_text('utf-8')) if path.exists() else {'jwtKey':secrets.token_urlsafe(48),'devices':{}}
    device=str(UUID(device_id)) if device_id else str(uuid4())
    if device in config['devices']:
        raise SystemExit('Device exists; refusing to overwrite credentials')
    secret=secrets.token_urlsafe(32)
    config['devices'][device]=hashlib.sha256(secret.encode()).hexdigest()
    temporary=data/'secrets.pending'
    temporary.write_text(json.dumps(config,indent=2),'utf-8')
    temporary.replace(path)
    output=data/f'device-{device}.json'
    output.write_text(json.dumps({'deviceId':device,'deviceSecret':secret,'baseUrl':'http://127.0.0.1:8765'},indent=2),'utf-8')
    print(f'Created local credential file: {output}')


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--data',type=Path,default=Path(__file__).parent/'data')
    parser.add_argument('--device-id')
    args=parser.parse_args()
    provision(args.data,args.device_id)

"""Manual loopback-only development service, bounded rotating logs, no auto-restart."""
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path
import shutil
import socket
import uvicorn

from backend.app import create_app

if __name__=='__main__':
    data=Path(__file__).parent/'data'
    data.mkdir(exist_ok=True)
    if shutil.disk_usage(data).free < 512*1024*1024:
        raise SystemExit('Need at least 512 MB free for persistent data and logs')
    with socket.socket() as check:
        check.bind(('127.0.0.1',8765))
    handler=RotatingFileHandler(data/'service.log',maxBytes=2*1024*1024,backupCount=3,encoding='utf-8')
    handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
    for name in ('uvicorn','uvicorn.error'):
        logger=logging.getLogger(name);logger.handlers=[handler];logger.setLevel(logging.INFO);logger.propagate=False
    uvicorn.run(create_app(),host='127.0.0.1',port=8765,log_config=None,access_log=False,limit_concurrency=32,timeout_keep_alive=5)

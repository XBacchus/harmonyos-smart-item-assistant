"""Loopback course API. Device ownership always comes from the verified JWT."""
import hashlib
import hmac
import json
import os
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated
from uuid import UUID, uuid4

import jwt
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, ConfigDict, Field, model_validator

ROOT = Path(__file__).resolve().parents[1]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)


class Credentials(StrictModel):
    deviceId: UUID
    deviceSecret: str = Field(min_length=24, max_length=256)


class Detection(StrictModel):
    id: str = Field(min_length=1, max_length=80)
    classId: int = Field(ge=0, le=79)
    originalClassId: int = Field(ge=0, le=79)
    confidence: float = Field(ge=0, le=1)
    x1: float = Field(ge=0)
    y1: float = Field(ge=0)
    x2: float = Field(gt=0)
    y2: float = Field(gt=0)
    deleted: bool
    edited: bool


class Timings(StrictModel):
    preprocessMs: float = Field(ge=0)
    inferenceMs: float = Field(ge=0)
    postprocessMs: float = Field(ge=0)
    loadMs: float = Field(ge=0)
    totalMs: float = Field(ge=0)


class Record(StrictModel):
    recordId: UUID
    revision: int = Field(ge=1, le=2147483647)
    createdAt: datetime
    updatedAt: datetime
    modelVersion: str = Field(min_length=1, max_length=100)
    width: int = Field(ge=1, le=16000)
    height: int = Field(ge=1, le=16000)
    confidenceThreshold: float = Field(ge=0.01, le=1)
    nmsThreshold: float = Field(ge=0.01, le=1)
    detections: list[Detection] = Field(max_length=100)
    timings: Timings

    @model_validator(mode='after')
    def valid_content(self):
        if not self.createdAt.tzinfo or not self.updatedAt.tzinfo:
            raise ValueError('UTC offset required')
        if self.updatedAt < self.createdAt:
            raise ValueError('updatedAt precedes createdAt')
        if len({d.id for d in self.detections}) != len(self.detections):
            raise ValueError('Duplicate detection ID')
        for d in self.detections:
            if not (d.x1 < d.x2 <= self.width and d.y1 < d.y2 <= self.height):
                raise ValueError('Detection bounds outside image')
        return self


class Batch(StrictModel):
    # Validate individually so one malformed record does not discard valid peers.
    records: list[dict] = Field(min_length=1, max_length=50)


def utc(value: datetime) -> str:
    if value.tzinfo is None:
        raise HTTPException(422, 'Timezone required')
    return value.astimezone(timezone.utc).isoformat(timespec='milliseconds')


def create_app(data_dir: Path | None = None, model_dir: Path | None = None, token_seconds: int = 900) -> FastAPI:
    data = data_dir or Path(os.environ.get('SMARTITEM_DATA', ROOT / 'backend/data'))
    models = model_dir or ROOT / 'models'
    data.mkdir(parents=True, exist_ok=True)
    config_file = data / 'secrets.json'
    if not config_file.exists():
        raise RuntimeError('Run backend/provision.py first; credentials are never auto-registered by HTTP')
    config = json.loads(config_file.read_text('utf-8'))
    signing_key = config['jwtKey']
    if len(signing_key) < 32:
        raise RuntimeError('JWT signing key too short')
    database = data / 'records.sqlite3'

    def connect():
        conn = sqlite3.connect(database, timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute('PRAGMA foreign_keys=ON')
        return conn

    with connect() as conn:
        conn.execute('PRAGMA journal_mode=WAL')
        conn.execute('CREATE TABLE IF NOT EXISTS records (device TEXT NOT NULL, id TEXT NOT NULL, revision INTEGER NOT NULL, created TEXT NOT NULL, updated TEXT NOT NULL, digest TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(device,id))')
        conn.execute('CREATE INDEX IF NOT EXISTS records_time ON records(device,created)')
    app = FastAPI(title='Smart Item Assistant', version='1.0.0')

    @app.middleware('http')
    async def limits(request: Request, call_next):
        request.state.request_id = str(uuid4())
        # Buffer only the bounded JSON endpoints, including chunked requests.
        if request.method == 'POST':
            chunks = bytearray()
            async for chunk in request.stream():
                chunks.extend(chunk)
                if len(chunks) > 2_000_000:
                    return JSONResponse({'error': {'code':'BODY_TOO_LARGE','message':'Maximum 2 MB','requestId':request.state.request_id,'retryable':False}},413)
            request._body = bytes(chunks)
        response = await call_next(request)
        response.headers['X-Request-ID'] = request.state.request_id
        response.headers['Cache-Control'] = 'no-store'
        return response

    @app.exception_handler(HTTPException)
    async def http_error(request, exc):
        return JSONResponse({'error':{'code':f'HTTP_{exc.status_code}','message':str(exc.detail),'requestId':request.state.request_id,'retryable':exc.status_code in (429,500,502,503,504)}},exc.status_code,headers=exc.headers)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, exc):
        # Do not echo request input; it may contain a device secret.
        return JSONResponse({'error':{'code':'INVALID_REQUEST','message':'Invalid request fields','requestId':request.state.request_id,'retryable':False}},422)

    def owner(authorization: Annotated[str | None, Header()] = None):
        if not authorization or not authorization.startswith('Bearer '):
            raise HTTPException(401,'Bearer token required')
        try:
            payload = jwt.decode(authorization[7:],signing_key,algorithms=['HS256'],issuer='smartitem',audience='smartitem-app',options={'require':['exp','iat','sub','iss','aud']})
            device = str(UUID(payload['sub']))
            if device not in config['devices']:
                raise ValueError('Unknown device')
            return device
        except (jwt.PyJWTError,ValueError,KeyError):
            raise HTTPException(401,'Invalid or expired token') from None

    failures: dict[str,list[float]] = {}

    @app.post('/api/v1/auth/token')
    def token(credentials: Credentials, request: Request):
        now = time.time()
        peer = request.client.host if request.client else 'unknown'
        attempts = [t for t in failures.get(peer,[]) if now-t<60]
        if len(attempts)>=15:
            raise HTTPException(429,'Try again in one minute',headers={'Retry-After':'60'})
        expected = config['devices'].get(str(credentials.deviceId),'0'*64)
        digest = hashlib.sha256(credentials.deviceSecret.encode()).hexdigest()
        if not hmac.compare_digest(digest,expected):
            failures[peer] = attempts+[now]
            raise HTTPException(401,'Invalid device credentials')
        failures.pop(peer,None)
        expires = int(now)+token_seconds
        encoded = jwt.encode({'sub':str(credentials.deviceId),'iat':int(now),'exp':expires,'iss':'smartitem','aud':'smartitem-app'},signing_key,algorithm='HS256')
        return {'accessToken':encoded,'tokenType':'Bearer','expiresAt':expires}

    def manifest():
        value = json.loads((models/'manifest.json').read_text('utf-8'))
        value['downloadPath'] = f"/api/v1/models/{value['version']}/file"
        value['labelsVersion'] = 'coco80-v1'
        return value

    @app.get('/api/v1/models/latest')
    def latest(device: str = Depends(owner)):
        return manifest()

    @app.get('/api/v1/models/{version}/file')
    def model_file(version: str, device: str = Depends(owner)):
        if version != manifest()['version']:
            raise HTTPException(404,'Model not found')
        return FileResponse(models/'yolov13n.onnx',media_type='application/octet-stream')

    @app.post('/api/v1/records/batch')
    def batch(body: Batch, device: str = Depends(owner)):
        answers = []
        with connect() as conn:
            conn.execute('BEGIN IMMEDIATE')
            for item in body.records:
                try:
                    record = Record.model_validate(item)
                except ValueError:
                    answers.append({'recordId':str(item.get('recordId',''))[:100],'acceptedRevision':0,'status':'invalid','error':'Invalid record schema or coordinates'})
                    continue
                rid = str(record.recordId)
                normalized = record.model_dump(mode='json')
                normalized['createdAt'],normalized['updatedAt'] = utc(record.createdAt),utc(record.updatedAt)
                payload = json.dumps(normalized,sort_keys=True,separators=(',',':'),ensure_ascii=False)
                digest = hashlib.sha256(payload.encode()).hexdigest()
                old = conn.execute('SELECT * FROM records WHERE device=? AND id=?',(device,rid)).fetchone()
                status = 'accepted'
                if old and record.revision < old['revision']:
                    status = 'stale'
                elif old and record.revision == old['revision']:
                    status = 'duplicate' if hmac.compare_digest(digest,old['digest']) else 'conflict'
                elif old and (normalized['createdAt']!=old['created'] or normalized['updatedAt']<old['updated']):
                    status = 'conflict'
                else:
                    conn.execute('INSERT INTO records VALUES (?,?,?,?,?,?,?) ON CONFLICT(device,id) DO UPDATE SET revision=excluded.revision,updated=excluded.updated,digest=excluded.digest,payload=excluded.payload',(device,rid,record.revision,normalized['createdAt'],normalized['updatedAt'],digest,payload))
                answers.append({'recordId':rid,'acceptedRevision':old['revision'] if old and status in ('stale','conflict') else record.revision,'status':status,'error':'Revision conflict' if status=='conflict' else ''})
        return {'results':answers}

    def filtered(conn, device, start, end, class_id):
        if start and end and start>=end:
            raise HTTPException(422,'from must precede to')
        sql, args = 'SELECT payload FROM records WHERE device=?',[device]
        if start:
            sql+=' AND created>=?'; args.append(utc(start))
        if end:
            sql+=' AND created<?'; args.append(utc(end))
        sql+=' ORDER BY created DESC,id DESC'
        values = [json.loads(row['payload']) for row in conn.execute(sql,args)]
        if class_id is not None:
            values = [r for r in values if any(d['classId']==class_id and not d['deleted'] for d in r['detections'])]
        return values

    @app.get('/api/v1/records')
    def records(device: str=Depends(owner), start: datetime|None=Query(None,alias='from'), end: datetime|None=Query(None,alias='to'), classId: int|None=Query(None,ge=0,le=79), page:int=Query(1,ge=1),pageSize:int=Query(20,ge=1,le=100)):
        with connect() as conn:
            rows=filtered(conn,device,start,end,classId)
        return {'items':rows[(page-1)*pageSize:page*pageSize],'total':len(rows),'page':page,'pageSize':pageSize}

    @app.get('/api/v1/stats')
    def stats(device:str=Depends(owner),start:datetime|None=Query(None,alias='from'),end:datetime|None=Query(None,alias='to'),classId:int|None=Query(None,ge=0,le=79)):
        with connect() as conn:
            rows=filtered(conn,device,start,end,classId)
        counts={}
        for record in rows:
            for d in record['detections']:
                if not d['deleted'] and (classId is None or d['classId']==classId):
                    counts[d['classId']]=counts.get(d['classId'],0)+1
        return {'recordCount':len(rows),'itemCount':sum(counts.values()),'byClass':[{'classId':k,'count':v} for k,v in sorted(counts.items())]}

    @app.get('/health/live')
    def live():
        return {'status':'alive'}

    @app.get('/health/ready')
    def ready():
        try:
            with connect() as conn:
                conn.execute('SELECT 1 FROM records LIMIT 1').fetchone()
            value = manifest()
            if (models/'yolov13n.onnx').stat().st_size != value['size']:
                raise ValueError('Model size mismatch')
        except (OSError,ValueError,sqlite3.Error):
            raise HTTPException(503,'Database or model unavailable') from None
        return {'status':'ready'}

    return app

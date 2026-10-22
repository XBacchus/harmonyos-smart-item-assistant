import hashlib
import json
import time
from copy import deepcopy
from uuid import uuid4

import jwt
import pytest
from fastapi.testclient import TestClient

from backend.app import create_app


@pytest.fixture
def api(tmp_path):
    ids=[str(uuid4()),str(uuid4())]
    secret='test-device-secret-'+'x'*24
    key='test-signing-key-'+'y'*48
    (tmp_path/'secrets.json').write_text(json.dumps({'jwtKey':key,'devices':{d:hashlib.sha256(secret.encode()).hexdigest() for d in ids}}),'utf-8')
    client=TestClient(create_app(tmp_path))
    headers=[]
    for device in ids:
        result=client.post('/api/v1/auth/token',json={'deviceId':device,'deviceSecret':secret})
        assert result.status_code==200
        headers.append({'Authorization':'Bearer '+result.json()['accessToken']})
    return client,headers,ids,key


def record():
    return {'recordId':str(uuid4()),'revision':1,'createdAt':'2026-10-22T00:00:00.000Z','updatedAt':'2026-10-22T00:00:00.000Z','modelVersion':'test-v1','width':100,'height':200,'confidenceThreshold':0.25,'nmsThreshold':0.45,'detections':[{'id':'d1','classId':41,'originalClassId':41,'confidence':0.9,'x1':1,'y1':2,'x2':80,'y2':150,'deleted':False,'edited':False}],'timings':{'preprocessMs':1,'inferenceMs':10,'postprocessMs':2,'loadMs':0,'totalMs':13}}


def send(client,headers,items):
    return client.post('/api/v1/records/batch',headers=headers,json={'records':items})


def test_auth_and_expiration(api):
    c,h,ids,key=api
    for path in ['/api/v1/records','/api/v1/stats','/api/v1/models/latest']:
        assert c.get(path).status_code==401
    bad=c.post('/api/v1/auth/token',json={'deviceId':ids[0],'deviceSecret':'wrong-'*8})
    assert bad.status_code==401
    assert 'wrong-' not in bad.text
    expired=jwt.encode({'sub':ids[0],'iat':int(time.time())-100,'exp':int(time.time())-1,'iss':'smartitem','aud':'smartitem-app'},key,algorithm='HS256')
    assert c.get('/api/v1/records',headers={'Authorization':'Bearer '+expired}).status_code==401
    assert c.get('/api/v1/records',headers=h[0]).status_code==200


def test_idempotency_revision_and_isolation(api):
    c,h,_,_=api
    r=record()
    assert send(c,h[0],[r]).json()['results'][0]['status']=='accepted'
    assert send(c,h[0],[r]).json()['results'][0]['status']=='duplicate'
    assert c.get('/api/v1/stats',headers=h[0]).json()['itemCount']==1
    assert c.get('/api/v1/records',headers=h[1]).json()['total']==0
    conflict=deepcopy(r);conflict['detections'][0]['classId']=67
    assert send(c,h[0],[conflict]).json()['results'][0]['status']=='conflict'
    conflict['revision']=2;conflict['updatedAt']='2026-10-22T01:00:00Z'
    assert send(c,h[0],[conflict]).json()['results'][0]['acceptedRevision']==2
    ack=send(c,h[0],[r]).json()['results'][0]
    assert ack['status']=='stale' and ack['acceptedRevision']==2
    stats=c.get('/api/v1/stats',headers=h[0]).json()
    assert stats['recordCount']==1 and stats['byClass']==[{'classId':67,'count':1}]


def test_partial_batch_deleted_and_filters(api):
    c,h,_,_=api
    a,b=record(),record()
    invalid=deepcopy(a);invalid['recordId']=str(uuid4());invalid['detections'][0]['x2']=101
    b['createdAt']=b['updatedAt']='2026-10-23T00:00:00Z'
    b['detections'][0]['deleted']=True
    response=send(c,h[0],[a,invalid,b]).json()['results']
    assert [r['status'] for r in response]==['accepted','invalid','accepted']
    assert c.get('/api/v1/records?classId=41',headers=h[0]).json()['total']==1
    assert c.get('/api/v1/records?from=2026-10-22T00:00:00Z&to=2026-10-23T00:00:00Z',headers=h[0]).json()['total']==1
    assert c.get('/api/v1/records?pageSize=1&page=2',headers=h[0]).json()['items'][0]['recordId']==a['recordId']
    assert c.get('/api/v1/stats',headers=h[0]).json()['itemCount']==1
    assert c.get('/api/v1/records?pageSize=101',headers=h[0]).status_code==422


def test_input_and_model_contract(api):
    c,h,_,_=api
    invalid=record();invalid['createdAt']='2026-10-22T00:00:00'
    assert send(c,h[0],[invalid]).json()['results'][0]['status']=='invalid'
    assert send(c,h[0],[]).status_code==422
    assert c.post('/api/v1/records/batch',headers=h[0],content=b'x'*2_000_001).status_code==413
    assert c.get('/api/v1/models/missing/file',headers=h[0]).status_code==404
    manifest=c.get('/api/v1/models/latest',headers=h[0]).json()
    assert manifest['inputShape']==[1,3,640,640]
    response=c.get(manifest['downloadPath'],headers=h[0])
    assert hashlib.sha256(response.content).hexdigest()==manifest['sha256']
    assert c.get('/health/ready').status_code==200


def test_same_id_is_device_scoped(api):
    c,h,_,_=api
    r=record()
    for headers in h:
        assert send(c,headers,[r]).json()['results'][0]['status']=='accepted'
        assert c.get('/api/v1/records',headers=headers).json()['total']==1

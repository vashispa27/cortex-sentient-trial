#!/usr/bin/env python3
"""Opt-in real Chrome identity tests; localhost pages, no model calls or form writes."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import threading
import time
import uuid
import urllib.request

ROOT=Path(__file__).resolve().parent
BIN=ROOT/'.build/sentient-native-trial'
class Page(BaseHTTPRequestHandler):
    title="Cortex origin identity fixture "+uuid.uuid4().hex[:8]
    def log_message(self,*_):pass
    def do_GET(self):
        self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers()
        self.wfile.write(('<title>'+self.title+'</title><h1>Identical tabs for targeting tests</h1><input aria-label="Fixture field">').encode())

def capture():
    return json.loads(subprocess.check_output([str(BIN),'--capture-origin'],text=True,timeout=5))

@contextmanager
def broker(origin):
    with tempfile.TemporaryDirectory(prefix='cortex-origin-test-') as work:
        target=Path(work)/'origin.json';target.write_text(json.dumps(origin))
        process=subprocess.Popen([str(BIN)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env={**os.environ,'CORTEX_TRIAL_ORIGIN_FILE':str(target)})
        try:
            ready=selectors.DefaultSelector();ready.register(process.stdout,selectors.EVENT_READ)
            assert ready.select(45),'Broker startup timed out'
            line=process.stdout.readline();assert line,process.stderr.read()
            config=json.loads(line)
            def call(tool,app=origin['app_path']):
                args={'app':app}
                if tool=='set_value':args.update(element_index='999999',value='MUST NOT BE TYPED')
                req=urllib.request.Request(config['url'],data=json.dumps({'jsonrpc':'2.0','id':time.time_ns(),'method':'tools/call','params':{'name':tool,'arguments':args}}).encode(),headers={'Authorization':'Bearer '+config['token'],'Content-Type':'application/json'})
                return json.load(urllib.request.urlopen(req,timeout=125))['result']
            yield call
        finally:
            process.stdin.close()
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=10)

def rejected(result):
    assert result.get('isError') is True
    assert 'ORIGIN_TARGET_BLOCKED' in json.dumps(result)

server=ThreadingHTTPServer(('127.0.0.1',0),Page)
threading.Thread(target=server.serve_forever,daemon=True).start()
url=f'http://127.0.0.1:{server.server_port}/'
try:
    subprocess.run(['open','-a','Google Chrome',url],check=True);time.sleep(.6)
    origin=capture()
    assert origin['app_path']=='/Applications/Google Chrome.app'
    with broker(origin) as call:
        observed=call('get_app_state');assert not observed.get('isError',False),observed
        rejected(call('set_value','/Applications/Safari.app'))
    print('PASS: original window read; action on another app rejected')
    with broker(origin) as call:
        subprocess.run(['open','-a','Google Chrome',url],check=True);time.sleep(.6)
        other=capture()
        assert other['window_id']==origin['window_id'] and other['tab_hash']!=origin['tab_hash']
        rejected(call('set_value'))
        rejected(call('get_app_state'))
    print('PASS: switching to an identical-title/URL tab rejects actions and latches the block')
    with broker(other) as call:
        subprocess.run(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','--new-window',url],capture_output=True,timeout=10)
        time.sleep(.8)
        third=capture();assert third['window_id']!=other['window_id']
        rejected(call('set_value'))
    print('PASS: switching Chrome windows rejects actions')
    with tempfile.TemporaryDirectory() as work:
        target=Path(work)/'origin.json';target.write_text(json.dumps({**third,'launch_timestamp':third['launch_timestamp']-1}))
        result=subprocess.run([str(BIN)],env={**os.environ,'CORTEX_TRIAL_ORIGIN_FILE':str(target)},input='',capture_output=True,text=True,timeout=10)
        assert result.returncode!=0 and 'exited or restarted' in result.stderr
    print('PASS: app process lifetime mismatch rejected at startup')
finally:
    server.shutdown();server.server_close()

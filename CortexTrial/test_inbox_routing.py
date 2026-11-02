"""Reproduce explicit-window routing and opening one background tab, using synthetic mail."""
import json
import os
import signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading
import time
import tempfile
from urllib.parse import parse_qs,urlsplit
import urllib.request
import uuid
from cortex_agent_api.settings import Settings

root=Path(__file__).resolve().parent
name='Cortex synthetic inbox '+uuid.uuid4().hex[:8]
class Inbox(BaseHTTPRequestHandler):
    opened=0
    queries=[]
    def log_message(self,*_):pass
    def do_GET(self):
        path=urlsplit(self.path)
        if path.path.startswith('/message/'):
            Inbox.opened+=1
            html='<title>Synthetic hiring email</title><h1>Grok daily startup hiring</h1><p>This is a local fixture, not a real email.</p>'
        else:
            query=parse_qs(path.query).get('q',[''])[0]
            if query:Inbox.queries.append(query)
            html=f'<title>{name}</title><style>body{{font:20px system-ui;margin:60px}}input,button{{font:inherit;padding:10px}}</style><h1>Synthetic inbox</h1><form><label>Search mail <input name="q"></label><button>Search</button></form>'
            if query:html+='<h2>1 matching email</h2><a href="/message/one">Grok daily startup hiring — synthetic email</a>'
        self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(html.encode())
server=ThreadingHTTPServer(('127.0.0.1',0),Inbox);threading.Thread(target=server.serve_forever,daemon=True).start()
url=f'http://127.0.0.1:{server.server_port}/'
s=Settings()
def request(path,body=None):
    req=urllib.request.Request('http://127.0.0.1:8790'+path,data=json.dumps(body).encode() if body is not None else None,headers={'Authorization':'Bearer '+s.api_token,'Content-Type':'application/json','Idempotency-Key':str(uuid.uuid4())})
    return json.load(urllib.request.urlopen(req,timeout=15))
job=None;started=time.monotonic();native_pid=None;profile=tempfile.TemporaryDirectory(prefix='cortex-inbox-browser-')
try:
    chrome=Path.home()/'Library/Caches/ms-playwright/chromium-1228/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'
    subprocess.run(['open','-n','-a',str(chrome.parents[2]),'--args','--user-data-dir='+profile.name,'--no-first-run','--no-default-browser-check',url],check=True)
    time.sleep(2)
    origin=json.loads(subprocess.check_output([str(root/'.build/sentient-native-trial'),'--capture-origin'],text=True,timeout=5))
    assert origin['app_path']==str(chrome.parents[2]),'Test browser is not foreground'
    native_pid=origin['pid']
    task='use this window, search emails for grok daily startup hiring and open one in a new background tab. This is the local synthetic inbox at '+url+'. Use only this fixture. Keep the original inbox tab selected. Verify the new email tab exists in the tab strip; do not switch to it. No real mail or external sites.'
    # Agent mode explicitly selects the native runner for every prompt.
    job=request('/v1/tasks',{'workflow':'agent','task':task,'use_native_window':True,'origin_target':origin,'limits':{'max_active_seconds':150}})
    assert job.get('runner')=='sentient_native',job
    print('Explicit request routed to:',job['runner'],'task:',job['task_id'],flush=True)
    deadline=time.monotonic()+180
    while time.monotonic()<deadline:
        current=request('/v1/tasks/'+job['task_id'])
        if current['status'] in {'completed','failed','cancelled'}:break
        time.sleep(1)
    after=json.loads(subprocess.check_output([str(root/'.build/sentient-native-trial'),'--capture-origin',str(native_pid)],text=True,timeout=5))
    print('Final:',current['status'],'elapsed:',round(time.monotonic()-started,2),'email page opens:',Inbox.opened,'origin unchanged:',after['window_id']==origin['window_id'] and after['tab_hash']==origin['tab_hash'],flush=True)
    if current.get('error'):print('Error:',current['error'],flush=True)
    assert current['status']=='completed'
    assert Inbox.opened==1 and any('grok' in q.lower() for q in Inbox.queries)
    assert after['window_id']==origin['window_id'] and after['tab_hash']==origin['tab_hash']
    print('PASS: correct runner, search performed, one background email tab opened, original target retained',flush=True)
finally:
    if job:
        current=request('/v1/tasks/'+job['task_id'])
        if current['status'] not in {'completed','failed','cancelled'}:request('/v1/tasks/'+job['task_id']+'/cancel',{'expected_version':current['version']})
    server.shutdown();server.server_close()
    if native_pid:
        try:os.kill(native_pid,signal.SIGTERM)
        except ProcessLookupError:pass
        time.sleep(.5)
    profile.cleanup()

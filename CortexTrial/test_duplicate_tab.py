"""Model-free real-browser test of controlled tab duplication and deduplication."""
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import json,os
from pathlib import Path
import selectors,signal,subprocess,tempfile,threading,time,urllib.request,uuid
ROOT=Path(__file__).resolve().parent;BIN=ROOT/'.build/sentient-native-trial'
TITLE='Cortex duplicate test '+uuid.uuid4().hex[:8]
class Page(BaseHTTPRequestHandler):
    visits=0
    def log_message(self,*_):pass
    def do_GET(self):
        if self.path.startswith('/message/one'):Page.visits+=1
        self.send_response(200);self.send_header('Content-Type','text/html');self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(('<title>'+TITLE+'</title><h1>Synthetic message</h1>').encode())
server=ThreadingHTTPServer(('127.0.0.1',0),Page);threading.Thread(target=server.serve_forever,daemon=True).start()
broker=None;pid=None
with tempfile.TemporaryDirectory(prefix='cortex-duplicate-test-') as work:
    try:
        chrome=Path.home()/'Library/Caches/ms-playwright/chromium-1228/chrome-mac-arm64/Google Chrome for Testing.app'
        url=f'http://127.0.0.1:{server.server_port}/message/one'
        subprocess.run(['open','-n','-a',str(chrome),'--args','--user-data-dir='+work+'/profile','--no-first-run','--no-default-browser-check',url],check=True);time.sleep(2)
        origin=json.loads(subprocess.check_output([str(BIN),'--capture-origin'],text=True,timeout=5));assert origin['app_path']==str(chrome);pid=origin['pid']
        target=Path(work)/'origin.json';target.write_text(json.dumps(origin))
        broker=subprocess.Popen([str(BIN)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env={**os.environ,'CORTEX_TRIAL_ORIGIN_FILE':str(target)})
        ready=selectors.DefaultSelector();ready.register(broker.stdout,selectors.EVENT_READ);assert ready.select(45)
        line=broker.stdout.readline();assert line,broker.stderr.read();config=json.loads(line)
        def call(name,args):
            req=urllib.request.Request(config['url'],data=json.dumps({'jsonrpc':'2.0','id':time.time_ns(),'method':'tools/call','params':{'name':name,'arguments':args}}).encode(),headers={'Authorization':'Bearer '+config['token'],'Content-Type':'application/json'})
            return json.load(urllib.request.urlopen(req,timeout=125))['result']
        state=call('get_app_state',{'app':origin['app_path']});assert not state.get('isError'),state
        result=call('duplicate_tab_in_background',{})
        if result.get('isError'):print(json.dumps(result),flush=True)
        assert not result.get('isError')
        after=json.loads(subprocess.check_output([str(BIN),'--capture-origin',str(pid)],text=True,timeout=5))
        assert after['window_id']==origin['window_id'] and after['tab_hash']==origin['tab_hash']
        assert Page.visits==2,Page.visits
        again=call('duplicate_tab_in_background',{});assert 'already duplicated' in json.dumps(again);assert Page.visits==2
        print('PASS: one duplicate, original tab restored, repeated URL does not create another tab',flush=True)
    finally:
        if broker:
            broker.stdin.close()
            try:broker.wait(timeout=10)
            except subprocess.TimeoutExpired:broker.terminate();broker.wait(timeout=10)
        if pid:
            try:os.kill(pid,signal.SIGTERM)
            except ProcessLookupError:pass
            time.sleep(.5)
        server.shutdown();server.server_close()

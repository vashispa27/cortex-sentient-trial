#!/usr/bin/env python3
"""Launch the forked Sentient native broker and existing Codex agent loop. No new agent loop.

--fixture uses synthetic localhost data; otherwise pass an explicit task with --task.
Logs are private to this trial, never added to Cortex memory or sent to telemetry.
"""
from __future__ import annotations
import argparse
from collections import Counter
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parent

class Fixture(BaseHTTPRequestHandler):
    submissions = []
    def log_message(self, *_): pass
    def do_GET(self):
        html = '''<!doctype html><title>Cortex native trial</title><meta charset="utf-8">
<style>body{font:20px system-ui;max-width:650px;margin:60px auto}label{display:block;margin:22px 0}input,select,button{font:inherit;padding:10px}button{margin:10px}</style>
<h1>Cortex native trial — synthetic form</h1><p>This local test sends no real application.</p>
<form method="post" action="/submit"><section id="one">
<label>Full name <input name="name" required></label><label>Email <input name="email" type="email" required></label>
<button type="button" onclick="document.querySelector('#one').hidden=true;document.querySelector('#two').hidden=false">Next</button></section>
<section id="two" hidden><label>City <input name="city" required></label>
<label>Plan <select name="plan"><option value="">Choose a plan</option><option>Basic</option><option>Pro</option></select></label>
<label><input type="checkbox" name="updates"> Receive product updates</label>
<button type="button" onclick="document.querySelector('#two').hidden=true;document.querySelector('#review').hidden=false;document.querySelector('#summary').textContent=JSON.stringify(Object.fromEntries(new FormData(document.querySelector('form'))))">Review</button></section>
<section id="review" hidden><h2>Review application</h2><pre id="summary"></pre><button type="submit">Submit test application</button></section></form>'''
        self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.end_headers(); self.wfile.write(html.encode())
    def do_POST(self):
        values = {k:v[0] for k,v in parse_qs(self.rfile.read(int(self.headers.get('Content-Length','0'))).decode()).items()}
        self.submissions.append(values)
        self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.end_headers()
        self.wfile.write(b'<title>Trial complete</title><h1>Submitted successfully</h1><p>Confirmation: CORTEX-TRIAL-001</p>')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--fixture',action='store_true')
    mode.add_argument('--task',help='Explicit computer task. Runs against your real apps.')
    mode.add_argument('--task-file',type=Path)
    parser.add_argument('--timeout',type=int,default=240)
    parser.add_argument('--origin-file',type=Path)
    parser.add_argument('--service',action='store_true')
    args=parser.parse_args()
    def stop_requested(_signal, _frame): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop_requested)
    os.umask(0o077)
    out=ROOT/'.runs'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'); out.mkdir(parents=True)
    server=None; broker=None; model=None
    started=time.monotonic(); stats=Counter(); usage={}; exit_code=1
    try:
        if args.fixture:
            Fixture.submissions=[]
            server=ThreadingHTTPServer(('127.0.0.1',0),Fixture)
            threading.Thread(target=server.serve_forever,daemon=True).start()
            url=f'http://127.0.0.1:{server.server_port}/'
            subprocess.run(['open','-a','Google Chrome',url],check=True)
            task=f'''Always identify the app using the full path /Applications/Google Chrome.app in every tool call. Use only Google Chrome and the local page titled Cortex native trial at {url}.
Fill and submit this synthetic test application: Full name = Alex Rivera; Email = alex@example.test;
City = Bengaluru; Plan = Pro; Receive product updates = unchecked.
Go through Next and Review, verify the values, then click Submit test application exactly once.
Submission of this local synthetic form is explicitly authorized. Verify confirmation CORTEX-TRIAL-001.
Do not access other sites or apps. All needed facts are provided. Do not ask for confirmation again.
If tools cannot work, state the specific blocker and stop. Never bypass missing permissions.'''
        else: task=args.task_file.read_text() if args.task_file else args.task
        origin=out/'origin.json'
        if args.origin_file:
            origin.write_bytes(args.origin_file.read_bytes())
        else:
            captured=subprocess.run([str(ROOT/'.build/sentient-native-trial'),'--capture-origin'],capture_output=True,text=True,timeout=5,check=True)
            origin.write_text(captured.stdout)
        target=json.loads(origin.read_text())
        task='The task is bound to this originating window/tab. Use app='+target['app_path']+' in every native call. Do not switch to existing other tabs/windows. When the user requests pages/emails in new tabs, open each result normally in the ORIGINAL tab, call duplicate_tab_in_background to create a verified background copy and restore the original selection, then navigate Back to the results before the next result. This is the reliable route for Gmail-style JavaScript message rows; do not rely on middle-click. Do not duplicate the search results page instead of opening a message. The tab tool handles its own brief new-tab creation/restoration. Recover routine UI obstacles using fresh state instead of giving up after one failed click.\n'+task
        stderr=(out/'broker.stderr').open('w')
        broker=subprocess.Popen([str(ROOT/'.build/sentient-native-trial')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,text=True,start_new_session=True,env={**os.environ,"CORTEX_TRIAL_ORIGIN_FILE":str(origin.resolve())})
        ready=selectors.DefaultSelector(); ready.register(broker.stdout,selectors.EVENT_READ)
        if not ready.select(55): raise RuntimeError('Native broker did not start within 55 seconds; see broker.stderr')
        line=broker.stdout.readline()
        if not line: raise RuntimeError('Native broker failed startup: '+(out/'broker.stderr').read_text()[-1500:])
        connection=json.loads(line)
        rules=(ROOT/'native-rules.txt').read_text()
        prompt=rules+'\n\nCORTEX TRIAL\nUse only sentient_native computer tools. No shell, browser CDP, connectors, diagnostics or permission changes.\n'+task
        bundled='/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
        cli=os.environ.get('CORTEX_TRIAL_CODEX',bundled if Path(bundled).is_file() else str(Path.home()/'.local/bin/codex'))
        with tempfile.TemporaryDirectory(prefix='cortex-native-task-') as work:
            command=[cli,'exec','--skip-git-repo-check','--ephemeral','--ignore-user-config','--json','-C',work,'--sandbox','danger-full-access']
            overrides=['mcp_servers={}','approval_policy="never"','features.shell_tool=false','features.apps=false','features.plugins=false','features.browser_use=false','features.computer_use=false','features.multi_agent=false','web_search="disabled"','project_doc_max_bytes=0']+connection['overrides']
            for override in overrides: command += ['-c',override]
            command += ['-o',str(out/'answer.txt'),'-']
            with (out/'events.jsonl').open('w') as events, (out/'model.stderr').open('w') as model_errors:
                model=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE if args.service else events,stderr=model_errors,text=True,start_new_session=True)
                model.stdin.write(prompt); model.stdin.close()
                if args.service:
                    def watch():
                        for line in model.stdout:
                            events.write(line); events.flush()
                            try: event=json.loads(line)
                            except json.JSONDecodeError: continue
                            item=event.get('item',{})
                            if item.get('type')=='mcp_tool_call' and event.get('type')=='item.completed':
                                blocked='ORIGIN_TARGET_BLOCKED' in line
                                print(json.dumps({'event':'tool','tool':item.get('tool'),'status':item.get('status'),'origin_blocked':blocked}),flush=True)
                                if blocked:
                                    os.killpg(model.pid,signal.SIGTERM)
                    watcher=threading.Thread(target=watch,daemon=True); watcher.start()
                try: exit_code=model.wait(timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    os.killpg(model.pid,signal.SIGTERM); model.wait(timeout=10); exit_code=124
        if args.service: watcher.join(timeout=5)
        for line in (out/'events.jsonl').read_text().splitlines():
            try: event=json.loads(line)
            except json.JSONDecodeError: continue
            if event.get('type')=='turn.completed': usage=event.get('usage',{})
            item=event.get('item',{})
            if item.get('type')=='mcp_tool_call' and event.get('type')=='item.completed':
                stats[item.get('tool','unknown')]+=1
        expected={'name':'Alex Rivera','email':'alex@example.test','city':'Bengaluru','plan':'Pro'}
        report={'upstream':json.loads((ROOT/'upstream.json').read_text()),'exit_code':exit_code,'elapsed_seconds':round(time.monotonic()-started,2),'tools':dict(stats),'fixture':args.fixture,'usage':usage,'model_selection':'Codex CLI default; not pinned'}
        if args.fixture:
            report.update(submissions=Fixture.submissions,passed=len(Fixture.submissions)==1 and Fixture.submissions[0]==expected)
        (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        if args.service:
            print(json.dumps({'event':'result','exit_code':exit_code,'response':(out/'answer.txt').read_text() if (out/'answer.txt').exists() else '', 'elapsed_seconds':report['elapsed_seconds']}),flush=True)
        else:
            print(json.dumps(report,indent=2)); print('Results:',out)
        if not args.service and (out/'answer.txt').exists(): print((out/'answer.txt').read_text())
        return 0 if exit_code==0 and (not args.fixture or report['passed']) else 1
    finally:
        if model and model.poll() is None:
            os.killpg(model.pid,signal.SIGTERM)
            try: model.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(model.pid,signal.SIGKILL); model.wait(timeout=10)
        if broker:
            if broker.stdin: broker.stdin.close()
            try: broker.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(broker.pid,signal.SIGTERM); broker.wait(timeout=10)
        if server: server.shutdown(); server.server_close()

if __name__=='__main__': raise SystemExit(main())

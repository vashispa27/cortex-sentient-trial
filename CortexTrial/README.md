# Cortex trial of Sentient native computer use

Current Cortex notch behavior: Agent mode always selects this native window/browser
runner. There is no extra window toggle or prompt router. Model-based routing and
long-running Agent-mode selection are deferred. Earlier sections retain trial history.

The controlled duplicate-tab action passes a real-browser test. The complete
five-message Gmail flow remains unverified; a saved rerun was blocked by stale
origin identity. This is an experimental implementation.

This is a local fork of Sentient OS at `fe28c9c14ddb5b2e63902ca137594e9c4e6bfdac`.
It reuses Sentient's native MCP broker, authenticated session, app-state validation,
read retry policy, error classification and HTTP transport. The agent loop is the
existing `codex exec` runtime. `run.py` only starts/stops those processes and runs a
local test fixture; it does not implement a new model/action loop.

The fork and adaptations remain under the root AGPL-3.0 license. OpenAI's signed
native helper is a separate installed dependency; its implementation is not part
of Sentient's source license. This experiment is separate from Cortex production.
Published fork: https://github.com/vashispa27/cortex-sentient-trial, branch `codex/cortex-native-trial`.

## Run

Requires macOS 15+, Swift command-line tools, an installed signed Codex computer-use
helper with its normal macOS grants, a current Codex CLI, and working Codex inference
authentication. Uses the CLI bundled in ChatGPT when present, otherwise `~/.local/bin/codex`.
Set `CORTEX_TRIAL_CODEX` for another supported executable. The helper is discovered in
`~/.codex/computer-use`; `CORTEX_TRIAL_CODEX_HOME` can select another installation.
These are process-local settings, not changes to user configuration.

```sh
cd /Users/abhinavvashisht/workspace/cortex-sentient-trial
./CortexTrial/build.sh
./CortexTrial/.build/sentient-native-trial --probe
python3 CortexTrial/run.py --fixture
```

The probe lists tool schemas without a model turn or UI action. The fixture opens a
localhost page in Chrome, fills synthetic data, navigates through two stages and a
review, and submits once. The fixture server independently checks the posted values.
Raw events and metrics are in gitignored `CortexTrial/.runs/` (owner-only permissions).
Native state may include screenshots; these raw logs are local and should not be published.

For an explicitly chosen real task:

```sh
python3 CortexTrial/run.py --task 'In /Applications/Google Chrome.app, ...' --timeout 300
```

That command operates real apps through native tools using the current CLI login.
It makes model calls. It is also reachable through Cortex's explicit "Use this window" option.
Cortex forwards a descriptor captured before opening compose; ordinary Agent mode
continues to use LangGraph. Native tasks use this fork's Codex CLI loop.
Use full app paths: a Chrome alert helper can share the localized name Google Chrome,
which Sentient's unique-target guard correctly treats as ambiguous.

The default model task deadline is 240 seconds, with bounded startup and shutdown
in addition. Each native request retains upstream deadlines. Ctrl+C stops owned
processes. No installer, TCC modification, helper takeover or force-quit of a shared
helper is included. Permission errors surface directly; no fake grant is used.

## Adaptations

- Seven native files copied into `src/`; originals remain in the fork for diffing.
- Sentient-specific diagnostic consent/UI removed from the broker. Native state IDs,
  duplicate request protection, stale-state checks and read retries remain upstream.
- Diagnostics hooks are inert; no telemetry or uploads. Permission failure notification
  has no local cache to invalidate; actual errors still reach the agent.
- `TrialSupport.swift` supplies installed-runtime discovery/signature validation and
  upstream-style MCP configuration. No persistent Codex config is rewritten.
- `TrialMain.swift` owns the broker lifetime until parent stdin closes.
- `native-rules.txt` is extracted from upstream's native operating guidance. The
  small Cortex trial suffix scopes the synthetic task and disables unrelated tools.
- Native session has opt-in stderr forwarding with `CORTEX_TRIAL_DEBUG=1`.
- The model invocation ignores user config so unrelated MCP servers are not started.
- Upstream session-recovery test points at the adapted native sources when present.

## Measured result, 2026-11-02

Successful live run `20261102T040809Z`: 52.12 seconds including runtime startup;
5 state reads, 3 set-value calls, 5 clicks; exactly one server-observed POST with
all expected values; agent observed confirmation `CORTEX-TRIAL-001`. No clarification
question or manual intervention was needed. The current test has no interactive
question tool; a task requiring a human answer must report its blocker.

An earlier attempt was stopped after 60.98 seconds because `Google Chrome` matched
both the browser and an alert process: 13 reads and 13 rejected action attempts,
zero submissions. Using the full application path resolved that integration issue.
The successful CLI run reported 299,863 input tokens (262,528 cached) and 706 output
tokens. These are cumulative model usage counters, not a dollar estimate. The trial
used the existing Codex login and CLI-default model, not a pinned model or the
OpenRouter model selected in Cortex. Future comparisons must control for this.
Neither attempt establishes performance on arbitrary sites or parity with Sentient's
full context/memory system. No controlled Browser Use comparison has been run.

`python3 Scripts/test_native_session_recovery.py` passed 1,047 real-process assertions
against the adapted broker/session sources, including reconnect, duplicate action
protection and stop behavior. The real helper catalog probe also passed.

## Next integration decision

Evaluate a chosen real task before replacing Cortex's Browser Use runner. A Cortex task adapter now forwards progress and STOP, with an immutable origin
descriptor. Durable native continuation and interactive questions remain pending.
Sentient's full app supplies those; this small native trial intentionally does not
claim to reproduce them or integrate LangGraph. Preserve upstream licensing if
incorporating this fork; treat helper distribution rights separately.

## Origin binding

`OriginTarget.swift` captures and retains the originating AX window/tab, checks app
PID/launch time and window identity, and refuses target changes. Native reads must
identify the same window, with ambiguous same-title windows refused. The broker
checks before and after dispatch and latches a mismatch. Native tools remain
app-scoped internally; this is surrounding verification, not an atomic window-ID
dispatch API. Configurations without stable identity are refused.

The CLI captures the current origin once unless `--origin-file` supplies Cortex's
saved descriptor. `--service` emits bounded tool/status events, not screenshots or
raw arguments, for Cortex's task adapter. Task text can travel in `--task-file`.
SIGTERM drains owned model and broker processes. Shared helpers are never killed.

`python3 CortexTrial/test_origin_binding.py` exercises real Chrome with local pages
and no model calls. It checks the original read, a rejected action on another app,
an identical-title/URL tab change, a different window and a changed process lifetime.
The test opens synthetic tabs/windows; it does not edit user pages.

The final full Cortex API test passed in 39.45 seconds with one independently
verified submission. Native scope tests and the 1,047 session-recovery assertions
also passed after binding was added.

## Controlled background tab creation

`duplicate_tab_in_background` duplicates the currently opened page with native
browser keys, verifies one new tab in the same window, restores the retained
original tab, and refuses a repeated URL in the same run. This supports
JavaScript message rows that do not behave like middle-clickable links: open the
message normally, duplicate it, then navigate Back in the original tab.

`python3 CortexTrial/test_duplicate_tab.py` passes using an isolated real Chromium
instance without model calls. The broker's 1,050 recovery/input assertions also
pass. These checks do not establish that the full Gmail task has succeeded.

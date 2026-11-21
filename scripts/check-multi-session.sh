#!/usr/bin/env bash
# Multi-session focus and popup check (AB-1, AB-2).
#
# Launches one Chromium with remote debugging, attaches 8 pinned
# agent-browser sessions (each in its own window via window new), drives them
# in parallel (snapshot, click, screenshot), and verifies:
#   1. the 8 session pages live in 8 distinct OS windows,
#   2. no session focus state changes during the parallel run, and in headed
#      mode every window keeps its windowId, windowState and bounds,
#   3. clicks and screenshots keep working in the background windows,
#   4. a target=_blank popup and its grandchild popup are adopted only by
#      the opener session (present in its tab list, absent from the others,
#      living in the owner window).
#
# Chromium is taken from AGENT_BROWSER_EXECUTABLE_PATH, else auto-detected:
# the newest Playwright chromium build on macOS or Linux, else a system
# chromium or google-chrome. Set HEADED=1 to run with a visible browser
# window instead of headless (used for the window bounds checks).
#
# Usage: scripts/check-multi-session.sh [--keep]
# Keeps all temp state under a fresh directory; --keep preserves it for
# inspection (the path is printed at the end).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/cli/target/debug/agent-browser"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
HEADED="${HEADED:-0}"

TMP="$(mktemp -d)/ab-check"
mkdir -p "$TMP/www" "$TMP/shots" "$TMP/socks" "$TMP/logs"
export AGENT_BROWSER_SOCKET_DIR="$TMP/socks"

PASS=0
FAIL=0
note() { printf '%s\n' "$1"; }
check() { # check <name> <ok: 1|0> [detail]
  if [ "$2" = 1 ]; then PASS=$((PASS + 1)); printf 'PASS  %s %s\n' "$1" "${3:-}"; else FAIL=$((FAIL + 1)); printf 'FAIL  %s %s\n' "$1" "${3:-}"; fi
}
now_ms() { # milliseconds; EPOCHREALTIME on bash 5+, else python3
  if [ -n "${EPOCHREALTIME:-}" ]; then
    awk "BEGIN { printf \"%d\", ${EPOCHREALTIME/./} / 1000 }"
  else
    python3 -c 'import time; print(int(time.time()*1000))'
  fi
}
cleanup() {
  [ -f "$TMP/chrome.pid" ] && kill "$(cat "$TMP/chrome.pid")" 2>/dev/null
  [ -f "$TMP/http.pid" ] && kill "$(cat "$TMP/http.pid")" 2>/dev/null
  for f in "$TMP"/socks/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
  [ "$KEEP" = 0 ] && rm -rf "$TMP"
}
trap cleanup EXIT

if [ ! -x "$BIN" ]; then
  note "debug binary missing, building (cargo build in cli/)..."
  (cd "$ROOT/cli" && cargo build) || { note "cargo build failed"; exit 1; }
fi

# --- Chromium ---------------------------------------------------------------
detect_chromium() {
  if [ -n "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ] && [ -x "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ]; then
    printf '%s\n' "$AGENT_BROWSER_EXECUTABLE_PATH"
    return 0
  fi
  local cand best=""
  for cand in "$HOME"/Library/Caches/ms-playwright/chromium-*/chrome-mac*/Google\ Chrome\ for\ Testing.app/Contents/MacOS/Google\ Chrome\ for\ Testing; do
    [ -x "$cand" ] && { best="$cand"; }
  done
  if [ -z "$best" ]; then
    for cand in "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux/chrome; do
      [ -x "$cand" ] && { best="$cand"; }
    done
  fi
  if [ -z "$best" ]; then
    for cand in /usr/bin/google-chrome-stable /usr/bin/google-chrome /usr/bin/chromium /usr/bin/chromium-browser /opt/google/chrome/chrome; do
      [ -x "$cand" ] && { best="$cand"; break; }
    done
  fi
  [ -n "$best" ] && printf '%s\n' "$best"
}
CHROME="$(detect_chromium)"
[ -n "$CHROME" ] || { note "no Chromium found (set AGENT_BROWSER_EXECUTABLE_PATH)"; exit 1; }
note "chromium: $CHROME (headed=$HEADED)"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
PROFILE="$TMP/profile"
if [ "$HEADED" = 1 ]; then
  "$CHROME" --remote-debugging-port="$PORT" --user-data-dir="$PROFILE" \
    --no-first-run --no-default-browser-check --window-size=1280,900 about:blank >/dev/null 2>&1 &
else
  "$CHROME" --headless --remote-debugging-port="$PORT" --user-data-dir="$PROFILE" \
    --no-first-run --no-default-browser-check about:blank >/dev/null 2>&1 &
fi
echo $! > "$TMP/chrome.pid"
for _ in $(seq 1 50); do curl -sf "http://localhost:$PORT/json/version" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://localhost:$PORT/json/version" >/dev/null 2>&1 || { note "chromium did not open CDP on $PORT"; exit 1; }

# --- Test pages ---------------------------------------------------------------
cat > "$TMP/www/index.html" <<'EOF'
<!doctype html><html><body>
<h1>hello</h1>
<button id="btn" onclick="document.getElementById('out').textContent='clicked'">press me</button>
<div id="out">not clicked</div>
<a id="pop" href="/popup.html" target="_blank">open popup</a>
</body></html>
EOF
cat > "$TMP/www/popup.html" <<'EOF'
<!doctype html><html><body>
<h1>popup</h1>
<a id="grand" href="/grandchild.html" target="_blank">open grandchild</a>
</body></html>
EOF
cat > "$TMP/www/grandchild.html" <<'EOF'
<!doctype html><html><body><h1>grandchild</h1></body></html>
EOF
HTTPPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
(cd "$TMP/www" && nohup python3 -m http.server "$HTTPPORT" >/dev/null 2>&1 & echo $! > "$TMP/http.pid")
PAGE="http://localhost:$HTTPPORT/"
sleep 1

ab() { with_timeout 120 "$BIN" --cdp "$PORT" --session "$1" --pin-tab --json "${@:2}"; }

with_timeout() { # with_timeout <secs> <cmd...>: guard against a wedged daemon
  secs="$1"; shift
  "$@" &
  pid=$!
  # The watchdog must not inherit our stdout: in a pipeline it would hold
  # the write end open and the reader would wait for EOF until it fires.
  ( sleep "$secs" && kill "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid"; code=$?
  kill "$watchdog" 2>/dev/null
  pkill -P "$watchdog" 2>/dev/null
  return "$code"
}

# --- 8 pinned sessions, each in its own window -------------------------------
note "attaching 8 pinned sessions..."
for i in $(seq 1 8); do
  ab "s$i" window new >"$TMP/logs/s$i-winnew.json" 2>&1 || { note "s$i window new failed"; cat "$TMP/logs/s$i-winnew.json"; exit 1; }
  ab "s$i" open "$PAGE" >"$TMP/logs/s$i-open.json" 2>&1 || { note "s$i open failed"; cat "$TMP/logs/s$i-open.json"; exit 1; }
done

tabs_of() { ab "$1" tab list 2>/dev/null | python3 -c 'import json,sys; [print(t["targetId"]) for t in json.load(sys.stdin)["data"]["tabs"] if t.get("active")]' 2>/dev/null || true; }
TARGETS=""
for i in $(seq 1 8); do TARGETS="$TARGETS $(tabs_of "s$i")"; done
N_TARGETS="$(echo "$TARGETS" | tr ' ' '\n' | grep -c .)"
[ "$N_TARGETS" = 8 ] && check "8 pinned sessions attached" 1 || { check "8 pinned sessions attached" 0; exit 1; }

# --- Window map via browser-level CDP -----------------------------------------
cat > "$TMP/window_map.py" <<'EOF'
# Prints JSON {targetId: {windowId, windowState, left, top, width, height}}
# using Browser.getWindowForTarget (bounds are included in its result).
import base64, json, os, socket, struct, sys, urllib.request
port, out = sys.argv[1], sys.argv[2]
tids = sys.argv[3:]
ver = json.load(urllib.request.urlopen(f"http://localhost:{port}/json/version"))
path = ver["webSocketDebuggerUrl"].split(f":{port}")[1]
s = socket.create_connection(("localhost", int(port)))
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
resp = b""
while b"\r\n\r\n" not in resp:
    resp += s.recv(4096)
def send(o):
    data = json.dumps(o).encode()
    hdr = bytes([0x81, 0x80 | len(data)]) if len(data) < 126 else struct.pack("!BBH", 0x81, 0x80 | 126, len(data))
    m = os.urandom(4)
    s.sendall(hdr + m + bytes(b ^ m[i % 4] for i, b in enumerate(data)))
for i, t in enumerate(tids):
    send({"id": i + 1, "method": "Browser.getWindowForTarget", "params": {"targetId": t}})
buf = b""
out_map = {}
s.settimeout(20)
while len(out_map) < len(tids):
    while len(buf) < 2:
        buf += s.recv(65536)
    b1, b2 = buf[0], buf[1]
    ln, off = b2 & 0x7F, 2
    if ln == 126:
        ln = struct.unpack("!H", buf[2:4])[0]; off = 4
    if b2 & 0x80:
        off += 4
    while len(buf) < off + ln:
        buf += s.recv(65536)
    payload = buf[off:off + ln]
    if b2 & 0x80:
        m = buf[off - 4:off]
        payload = bytes(b ^ m[i % 4] for i, b in enumerate(payload))
    buf = buf[off + ln:]
    if b1 & 0x0F == 0x1:
        m = json.loads(payload)
        if "result" in m:
            r = m["result"]
            out_map[tids[m["id"] - 1]] = {"windowId": r["windowId"], "bounds": r.get("bounds", {})}
json.dump(out_map, open(out, "w"), sort_keys=True)
EOF
# shellcheck disable=SC2086
python3 "$TMP/window_map.py" "$PORT" "$TMP/windows-before.json" $TARGETS
N_WINDOWS="$(python3 -c 'import json; print(len(set(v["windowId"] for v in json.load(open("'"$TMP/windows-before.json"'")).values())))')"
[ "$N_WINDOWS" = 8 ] && check "8 distinct windowIds" 1 || check "8 distinct windowIds" 0

focus_state() { ab "$1" eval "document.hasFocus()+' '+document.visibilityState" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("result","?"))' 2>/dev/null || true; }
BEFORE=""
for i in $(seq 1 8); do BEFORE="$BEFORE$(focus_state "s$i")|"; done

# --- Parallel drive -----------------------------------------------------------
note "driving 8 sessions in parallel..."
drive_one() { # drive_one <n>
  n="$1"
  snap_t0="$(now_ms)"; snap="$(ab "s$n" snapshot 2>/dev/null)"; snap_t1="$(now_ms)"
  btn="$(printf '%s' "$snap" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(("@" + k.lstrip("@") for k,v in d["data"]["refs"].items() if v.get("role")=="button"), ""))' 2>/dev/null || true)"
  echo "$((snap_t1 - snap_t0))" > "$TMP/logs/lat-snapshot-$n"
  if [ -z "$btn" ]; then echo "no-button" > "$TMP/logs/status-$n"; return; fi
  click_t0="$(now_ms)"; ab "s$n" click "$btn" >/dev/null 2>&1; click_t1="$(now_ms)"
  echo "$((click_t1 - click_t0))" > "$TMP/logs/lat-click-$n"
  shot_t0="$(now_ms)"; ab "s$n" screenshot "$TMP/shots/s$n.png" >/dev/null 2>&1; shot_t1="$(now_ms)"
  echo "$((shot_t1 - shot_t0))" > "$TMP/logs/lat-shot-$n"
  echo ok > "$TMP/logs/status-$n"
}
# NOTE: plain `wait` would also wait for the backgrounded Chromium and
# HTTP server started above, which outlive the whole script. Wait only for
# the driver jobs by pid.
PIDS=""
for i in $(seq 1 8); do drive_one "$i" & PIDS="$PIDS $!"; done
for p in $PIDS; do wait "$p"; done
ALL_OK=1
for i in $(seq 1 8); do [ "$(cat "$TMP/logs/status-$i" 2>/dev/null)" = ok ] || ALL_OK=0; done
check "parallel snapshot+click+screenshot" "$ALL_OK"

pct() { # pct <q> <files...>: prints ms
  python3 -c 'import sys; xs=sorted(int(open(f).read()) for f in sys.argv[2:]); q=float(sys.argv[1]); print(xs[min(len(xs)-1,int(q*(len(xs)-1)))])' "$@"
}
SNAP_FILES=""; CLICK_FILES=""; SHOT_FILES=""
for i in $(seq 1 8); do SNAP_FILES="$SNAP_FILES $TMP/logs/lat-snapshot-$i"; CLICK_FILES="$CLICK_FILES $TMP/logs/lat-click-$i"; SHOT_FILES="$SHOT_FILES $TMP/logs/lat-shot-$i"; done
# shellcheck disable=SC2086
SNAP_P50="$(pct 0.5 $SNAP_FILES)"; SNAP_P95="$(pct 0.95 $SNAP_FILES)"
# shellcheck disable=SC2086
CLICK_P50="$(pct 0.5 $CLICK_FILES)"; CLICK_P95="$(pct 0.95 $CLICK_FILES)"
# shellcheck disable=SC2086
SHOT_P50="$(pct 0.5 $SHOT_FILES)"; SHOT_P95="$(pct 0.95 $SHOT_FILES)"

CLICKED=1
for i in $(seq 1 8); do
  OUT="$(ab "s$i" eval "document.getElementById('out').textContent" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("result","?"))' 2>/dev/null || true)"
  SHOT_OK=1; [ -s "$TMP/shots/s$i.png" ] || SHOT_OK=0
  [ "$OUT" = clicked ] && [ "$SHOT_OK" = 1 ] || CLICKED=0
done
check "clicks landed in background windows" "$CLICKED"
SHOTS=1; for i in $(seq 1 8); do [ -s "$TMP/shots/s$i.png" ] || SHOTS=0; done
check "8 screenshots captured" "$SHOTS"

# --- Windows and focus unchanged -----------------------------------------------
# shellcheck disable=SC2086
python3 "$TMP/window_map.py" "$PORT" "$TMP/windows-after.json" $TARGETS
python3 - "$TMP/windows-before.json" "$TMP/windows-after.json" <<'EOF' > "$TMP/logs/windows-cmp.txt"
import json, sys
before, after = (json.load(open(p)) for p in sys.argv[1:3])
assert set(before) == set(after), "target set changed"
assert all(before[t]["windowId"] == after[t]["windowId"] for t in before), "window moved"
b = sorted(v["windowId"] for v in before.values())
print("windows=%d distinct=%d" % (len(b), len(set(b))))
EOF
WINDOWS_SAME="$?"
WINDOWS_DETAIL="$(cat "$TMP/logs/windows-cmp.txt" 2>/dev/null)"
[ "$WINDOWS_SAME" = 0 ] && check "every window kept its windowId" 1 "($WINDOWS_DETAIL)" || check "every window kept its windowId" 0 "($WINDOWS_DETAIL)"
if [ "$HEADED" = 1 ]; then
  python3 - "$TMP/windows-before.json" "$TMP/windows-after.json" <<'EOF'
import json, sys
before, after = (json.load(open(p)) for p in sys.argv[1:3])
assert all(before[t]["bounds"] == after[t]["bounds"] for t in before), "bounds changed"
EOF
  [ "$?" = 0 ] && check "windowState/bounds unchanged (headed)" 1 || check "windowState/bounds unchanged (headed)" 0
fi

AFTER=""
for i in $(seq 1 8); do AFTER="$AFTER$(focus_state "s$i")|"; done
[ "$BEFORE" = "$AFTER" ] && check "focused window unchanged during run" 1 "($BEFORE)" || check "focused window unchanged during run" 0 "(before $BEFORE after $AFTER)"

# --- Popup and grandchild ownership --------------------------------------------
note "testing popup ownership..."
LINK="$(ab s1 snapshot 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(("@" + k.lstrip("@") for k,v in d["data"]["refs"].items() if v.get("role")=="link"), ""))' 2>/dev/null || true)"
[ -n "$LINK" ] || { check "popup link found" 0; LINK=""; }
if [ -n "$LINK" ]; then
  ab s1 click "$LINK" >/dev/null 2>&1
  FOUND=0
  for _ in $(seq 1 40); do
    ab s1 tab list 2>/dev/null | grep -q popup.html && { FOUND=1; break; }
    sleep 0.5
  done
  check "popup in opener tab list (s1)" "$FOUND"
  if [ "$FOUND" = 1 ]; then
    POPUP_TARGET="$(ab s1 tab list 2>/dev/null | python3 -c 'import json,sys; print([t["targetId"] for t in json.load(sys.stdin)["data"]["tabs"] if "popup.html" in t.get("url","")][0])')"
    ab s1 tab "$POPUP_TARGET" >/dev/null 2>&1
    GLINK="$(ab s1 snapshot 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(("@" + k.lstrip("@") for k,v in d["data"]["refs"].items() if v.get("role")=="link"), ""))' 2>/dev/null || true)"
    [ -n "$GLINK" ] && ab s1 click "$GLINK" >/dev/null 2>&1
    GFOUND=0
    for _ in $(seq 1 40); do
      ab s1 tab list 2>/dev/null | grep -q grandchild.html && { GFOUND=1; break; }
      sleep 0.5
    done
    check "grandchild popup in opener tab list (s1)" "$GFOUND"
    ABSENT=1
    for i in $(seq 2 8); do
      if ab "s$i" tab list 2>/dev/null | grep -qE "popup.html|grandchild.html"; then ABSENT=0; fi
    done
    check "popup and grandchild absent from s2..s8" "$ABSENT"
    python3 "$TMP/window_map.py" "$PORT" "$TMP/windows-popup.json" "$POPUP_TARGET" $TARGETS
    python3 - "$TMP/windows-popup.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
tids = list(m)
owner_window = m[tids[1]]["windowId"]
assert m[tids[0]]["windowId"] == owner_window, "popup left the owner window"
EOF
    [ "$?" = 0 ] && check "popup lives in the owner window" 1 || check "popup lives in the owner window" 0
  fi
fi

# --- Summary ------------------------------------------------------------------
printf '\n%-38s %s\n' "check" "result"
printf '%-38s %s\n' "mode" "headed=$HEADED chromium=$CHROME"
printf '%-38s %s\n' "snapshot latency p50/p95" "${SNAP_P50}ms / ${SNAP_P95}ms"
printf '%-38s %s\n' "click latency p50/p95" "${CLICK_P50}ms / ${CLICK_P95}ms"
printf '%-38s %s\n' "screenshot latency p50/p95" "${SHOT_P50}ms / ${SHOT_P95}ms"
printf '%-38s %s\n' "total" "$PASS passed, $FAIL failed"
note "temp state: $TMP (removed on exit unless --keep)"
[ "$FAIL" = 0 ]

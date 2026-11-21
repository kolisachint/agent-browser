#!/bin/bash
# Verify AB-3 (per-session download folders) and AB-4 (reattach to a bound
# CDP endpoint) against one real headless Chromium.
#
# Usage: scripts/check-downloads-reattach.sh
#
# Flow:
#   1. Launch one headless Chromium (Playwright's chromium-1243) with a
#      remote debugging port and a temp profile.
#   2. Serve a page with two download links (Content-Disposition: attachment).
#   3. Attach pinned sessions a and b to the same browser with distinct
#      --download-path dirs, click both links at the same time, and check
#      each file lands only in its own folder with each wait --download
#      reporting its own path.
#   4. Kill session a's daemon, then run a command without --cdp: it must
#      reattach to the same tab (same targetId) without starting a new
#      browser (Chromium process count unchanged).
#   5. Kill Chromium: the next command on a must fail with a clear error
#      and must not start a new browser process.
#
# Prints a pass/fail summary with timings. Exits 0 only if every check passes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BIN="$PROJECT_ROOT/cli/target/debug/agent-browser"

PASS=0
FAIL=0
declare -a RESULTS=()

check() {
    local name="$1" status="$2" detail="${3:-}"
    if [ "$status" = "pass" ]; then
        PASS=$((PASS + 1))
        RESULTS+=("PASS  $name${detail:+ ($detail)}")
    else
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  $name${detail:+ ($detail)}")
    fi
    echo "[$status] $name${detail:+ -- $detail}"
}

START_ALL=$SECONDS

# --- prerequisites -----------------------------------------------------------
if [ ! -x "$BIN" ]; then
    echo "building agent-browser..."
    (cd "$PROJECT_ROOT/cli" && cargo build) || {
        echo "cargo build failed"
        exit 1
    }
fi

CHROME=""
for candidate in ~/Library/Caches/ms-playwright/chromium-1243/chrome-mac*/Google\ Chrome\ for\ Testing.app/Contents/MacOS/Google\ Chrome\ for\ Testing; do
    if [ -x "$candidate" ]; then
        CHROME="$candidate"
        break
    fi
done
if [ -z "$CHROME" ]; then
    echo "no Playwright chromium-1243 install found"
    exit 1
fi

for tool in python3 curl; do
    command -v "$tool" >/dev/null || {
        echo "missing $tool"
        exit 1
    }
done

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

HTTP_PORT="$(free_port)"
CDP_PORT="$(free_port)"

SOCK_DIR="$(mktemp -d)"
TPROF="$(mktemp -d)"
DL_A="$TPROF-dl-a"
DL_B="$TPROF-dl-b"
mkdir -p "$DL_A" "$DL_B"
export AGENT_BROWSER_SOCKET_DIR="$SOCK_DIR"

SERVER_PY="$TPROF/server.py"
cat >"$SERVER_PY" <<EOF
import http.server, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            body = (b'<html><body><h1>dl</h1>'
                    b'<a id="dl-a" href="/a.bin">a</a> '
                    b'<a id="dl-b" href="/b.bin">b</a></body></html>')
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path in ("/a.bin", "/b.bin"):
            time.sleep(2)
            name = "file-a.bin" if self.path == "/a.bin" else "file-b.bin"
            body = b"A" * 65536 if self.path == "/a.bin" else b"B" * 65536
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", $HTTP_PORT), H).serve_forever()
EOF

PAGE_URL="http://127.0.0.1:$HTTP_PORT/"

cleanup() {
    pkill -f "user-data-dir=$TPROF" 2>/dev/null || true
    for s in a b; do
        if [ -f "$SOCK_DIR/$s.pid" ]; then
            kill -9 "$(cat "$SOCK_DIR/$s.pid")" 2>/dev/null || true
        fi
    done
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$SOCK_DIR" "$TPROF" "$DL_A" "$DL_B"
}
trap cleanup EXIT

chrome_count() {
    pgrep -f "user-data-dir=$TPROF" 2>/dev/null | wc -l | tr -d ' '
}

active_target() {
    local session="$1"
    "$BIN" --session "$session" tab list --json 2>/dev/null |
        python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print([t['targetId'] for t in d['tabs'] if t.get('active')][0])"
}

reported_path() {
    python3 -c "import json,sys; print(json.load(sys.stdin)['data']['path'])"
}

# --- phase 1: shared browser + page ------------------------------------------
T0=$SECONDS
python3 "$SERVER_PY" &
SERVER_PID=$!
"$CHROME" --headless --no-sandbox --disable-gpu --no-first-run --no-default-browser-check \
    --remote-debugging-port="$CDP_PORT" --user-data-dir="$TPROF" about:blank \
    >/dev/null 2>&1 &
for _ in $(seq 1 60); do
    curl -sf -m 2 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null && break
    sleep 0.5
done
PHASE1_OK=0
curl -sf -m 2 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null &&
    curl -sf -m 2 "$PAGE_URL" >/dev/null && PHASE1_OK=1
if [ "$PHASE1_OK" -eq 1 ]; then S=pass; else S=fail; fi
check "one headless Chromium serves CDP and the test page" "$S" "$((SECONDS - T0))s"
CHROME_COUNT_START="$(chrome_count)"

# --- phase 2: AB-3 parallel downloads ----------------------------------------
T0=$SECONDS
"$BIN" --session a --cdp "$CDP_PORT" --pin-tab --download-path "$DL_A" \
    open "$PAGE_URL" >/dev/null 2>&1
OPEN_A=$?
"$BIN" --session b --cdp "$CDP_PORT" --pin-tab --download-path "$DL_B" \
    tab new "$PAGE_URL" >/dev/null 2>&1
OPEN_B=$?
if [ "$OPEN_A" -eq 0 ] && [ "$OPEN_B" -eq 0 ]; then S=pass; else S=fail; fi
check "sessions a and b attach pinned to the shared browser" "$S" "$((SECONDS - T0))s"

T0=$SECONDS
TARGET_A_BEFORE="$(active_target a)"
TARGET_B_BEFORE="$(active_target b)"
if [ -n "$TARGET_A_BEFORE" ] && [ -n "$TARGET_B_BEFORE" ] &&
    [ "$TARGET_A_BEFORE" != "$TARGET_B_BEFORE" ]; then S=pass; else S=fail; fi
check "a and b own different tabs" "$S" \
    "a=${TARGET_A_BEFORE:0:8} b=${TARGET_B_BEFORE:0:8} $((SECONDS - T0))s"

T0=$SECONDS
"$BIN" --session a --cdp "$CDP_PORT" click "#dl-a" >/dev/null 2>&1 &
CLICK_A=$!
"$BIN" --session b --cdp "$CDP_PORT" click "#dl-b" >/dev/null 2>&1 &
CLICK_B=$!
wait "$CLICK_A"
CLICK_RA=$?
wait "$CLICK_B"
CLICK_RB=$?
if [ "$CLICK_RA" -eq 0 ] && [ "$CLICK_RB" -eq 0 ]; then S=pass; else S=fail; fi
check "both download links clicked at the same time" "$S" "$((SECONDS - T0))s"

T0=$SECONDS
"$BIN" --session a --cdp "$CDP_PORT" wait --download --timeout 60000 --json \
    >"$TPROF/wait-a.json" 2>&1 &
WAIT_A=$!
"$BIN" --session b --cdp "$CDP_PORT" wait --download --timeout 60000 --json \
    >"$TPROF/wait-b.json" 2>&1 &
WAIT_B=$!
wait "$WAIT_A"
WAIT_RA=$?
wait "$WAIT_B"
WAIT_RB=$?
if [ "$WAIT_RA" -eq 0 ] && [ "$WAIT_RB" -eq 0 ]; then S=pass; else S=fail; fi
check "each wait --download succeeds" "$S" "$((SECONDS - T0))s"

T0=$SECONDS
PATH_A="$(reported_path <"$TPROF/wait-a.json" 2>/dev/null || true)"
PATH_B="$(reported_path <"$TPROF/wait-b.json" 2>/dev/null || true)"
if [ "$PATH_A" = "$DL_A/file-a.bin" ] && [ "$PATH_B" = "$DL_B/file-b.bin" ]; then S=pass; else S=fail; fi
check "each wait reports its own path" "$S" \
    "a=$PATH_A b=$PATH_B $((SECONDS - T0))s"

FILE_A_OK=0
FILE_B_OK=0
[ -f "$DL_A/file-a.bin" ] && [ ! -e "$DL_B/file-a.bin" ] &&
    [ "$(wc -c <"$DL_A/file-a.bin" | tr -d ' ')" = "65536" ] &&
    [ "$(head -c 1 "$DL_A/file-a.bin")" = "A" ] && FILE_A_OK=1
[ -f "$DL_B/file-b.bin" ] && [ ! -e "$DL_A/file-b.bin" ] &&
    [ "$(wc -c <"$DL_B/file-b.bin" | tr -d ' ')" = "65536" ] &&
    [ "$(head -c 1 "$DL_B/file-b.bin")" = "B" ] && FILE_B_OK=1
if [ "$FILE_A_OK" -eq 1 ]; then S=pass; else S=fail; fi
check "file-a.bin only in a's folder with a's bytes" "$S"
if [ "$FILE_B_OK" -eq 1 ]; then S=pass; else S=fail; fi
check "file-b.bin only in b's folder with b's bytes" "$S"

# --- phase 3: AB-4 daemon death reattaches -----------------------------------
T0=$SECONDS
CHROME_COUNT_BEFORE="$(chrome_count)"
DAEMON_A="$(cat "$SOCK_DIR/a.pid")"
kill -9 "$DAEMON_A"
for _ in $(seq 1 20); do
    kill -0 "$DAEMON_A" 2>/dev/null || break
    sleep 0.5
done
if kill -0 "$DAEMON_A" 2>/dev/null; then S=fail; else S=pass; fi
check "session a's daemon is dead" "$S" "$((SECONDS - T0))s"

T0=$SECONDS
# Deliberately no --cdp: the reattach must come from the persisted binding.
"$BIN" --session a tab list --json >"$TPROF/reattach.json" 2>"$TPROF/reattach.err"
REATTACH_EXIT=$?
TARGET_A_AFTER=""
[ "$REATTACH_EXIT" -eq 0 ] &&
    TARGET_A_AFTER="$(python3 -c "import json; d=json.load(open('$TPROF/reattach.json'))['data']; print([t['targetId'] for t in d['tabs'] if t.get('active')][0])" 2>/dev/null || true)"
CHROME_COUNT_AFTER="$(chrome_count)"
if [ "$REATTACH_EXIT" -eq 0 ] && [ "$TARGET_A_AFTER" = "$TARGET_A_BEFORE" ] &&
    [ "$CHROME_COUNT_AFTER" = "$CHROME_COUNT_BEFORE" ]; then S=pass; else S=fail; fi
check "a reattaches to the same tab with no new browser" "$S" \
    "target=${TARGET_A_AFTER:0:8} chrome=$CHROME_COUNT_BEFORE->$CHROME_COUNT_AFTER $((SECONDS - T0))s"

# --- phase 4: AB-4 dead endpoint errors clearly -------------------------------
T0=$SECONDS
pkill -f "user-data-dir=$TPROF"
for _ in $(seq 1 20); do
    [ "$(chrome_count)" = "0" ] && break
    sleep 0.5
done
KILLED_OK=0
[ "$(chrome_count)" = "0" ] && KILLED_OK=1
if [ "$KILLED_OK" -eq 1 ]; then S=pass; else S=fail; fi
check "test Chromium is fully stopped" "$S" "$((SECONDS - T0))s"

T0=$SECONDS
"$BIN" --session a tab list --json >"$TPROF/dead.json" 2>"$TPROF/dead.err"
DEAD_EXIT=$?
DEAD_OUT="$(cat "$TPROF/dead.json" "$TPROF/dead.err")"
sleep 2
CHROME_COUNT_DEAD="$(chrome_count)"
if [ "$DEAD_EXIT" -ne 0 ] && [ "$CHROME_COUNT_DEAD" = "0" ] &&
    echo "$DEAD_OUT" | grep -qiE "127\.0\.0\.1|$CDP_PORT|CDP|refused"; then S=pass; else S=fail; fi
check "dead endpoint errors clearly with no new browser" "$S" \
    "exit=$DEAD_EXIT chrome=$CHROME_COUNT_DEAD $((SECONDS - T0))s"

# --- summary -----------------------------------------------------------------
echo
echo "AB-3/AB-4 check summary (CDP $CDP_PORT, $CHROME_COUNT_START browser procs at start, total $((SECONDS - START_ALL))s):"
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

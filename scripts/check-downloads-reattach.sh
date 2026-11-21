#!/bin/bash
# Verify AB-3 (per-session download folders) and AB-4 (CDP reattach) against
# one real Chromium.
#
# Flow:
#   1. Launch one Chromium (Playwright build or system install) with a
#      remote debugging port and a temp profile.
#   2. Serve a page with download links plus a popup page with its own
#      download link.
#   3. Attach pinned own-window sessions a and b to the same browser with
#      distinct --download-path dirs, click both download links at the same
#      time, and check each file lands only in its own folder with each wait
#      --download reporting its own path. A download triggered from a's own
#      popup goes to a's folder.
#   4. Attach with a credentialed CDP URL: the endpoint must not persist.
#   5. Kill session a's daemon, then run a command without --cdp: it must
#      reattach to the same tab with ownership restored and without starting
#      a new browser (Chromium process count unchanged).
#   6. Restart Chromium on the SAME port with a fresh profile: reattach must
#      be refused with a clear different-browser error and no new browser
#      started.
#   7. Kill Chromium: the next command on a must fail with a clear error
#      and must not start a new browser process.
#
# Chromium comes from AGENT_BROWSER_EXECUTABLE_PATH, else the newest
# Playwright chromium on macOS or Linux, else a system install. HEADED=1
# runs Chromium with a visible window instead of headless.
#
# Prints a pass/fail summary with timings. Exits 0 only if every check passes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BIN="$PROJECT_ROOT/cli/target/debug/agent-browser"
HEADED="${HEADED:-0}"

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

detect_chromium() {
    if [ -n "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ] && [ -x "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ]; then
        printf '%s\n' "$AGENT_BROWSER_EXECUTABLE_PATH"
        return 0
    fi
    local cand best=""
    for cand in "$HOME"/Library/Caches/ms-playwright/chromium-*/chrome-mac*/Google\ Chrome\ for\ Testing.app/Contents/MacOS/Google\ Chrome\ for\ Testing; do
        [ -x "$cand" ] && best="$cand"
    done
    if [ -z "$best" ]; then
        for cand in "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux/chrome; do
            [ -x "$cand" ] && best="$cand"
        done
    fi
    if [ -z "$best" ]; then
        for cand in /usr/bin/google-chrome-stable /usr/bin/google-chrome /usr/bin/chromium /usr/bin/chromium-browser /opt/google/chrome/chrome; do
            [ -x "$cand" ] && { best="$cand"; break; }
        done
    fi
    [ -n "$best" ] && printf '%s\n' "$best"
}
CHROME="$(detect_chromium || true)"
if [ -z "$CHROME" ]; then
    echo "no Chromium found (set AGENT_BROWSER_EXECUTABLE_PATH)"
    exit 1
fi
echo "chromium: $CHROME (headed=$HEADED)"

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
    def page(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def blob(self, name, byte, delay):
        time.sleep(delay)
        body = bytes([byte]) * 65536
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/":
            self.page(b'<html><body><h1>dl</h1>'
                      b'<a id="dl-a" href="/a.bin">a</a> '
                      b'<a id="dl-b" href="/b.bin">b</a> '
                      b'<a id="pop" href="/popup.html" target="_blank">popup</a></body></html>')
        elif self.path == "/popup.html":
            self.page(b'<html><body><h1>popup</h1>'
                      b'<a id="dl-c" href="/c.bin">c</a></body></html>')
        elif self.path == "/a.bin":
            self.blob("file-a.bin", 65, 2)
        elif self.path == "/b.bin":
            self.blob("file-b.bin", 66, 2)
        elif self.path == "/c.bin":
            self.blob("file-c.bin", 67, 2)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", $HTTP_PORT), H).serve_forever()
EOF

PAGE_URL="http://127.0.0.1:$HTTP_PORT/"

CHROME_HEADLESS_ARGS=(--headless --no-sandbox --disable-gpu --no-first-run --no-default-browser-check)
CHROME_HEADED_ARGS=(--no-first-run --no-default-browser-check --window-size=1280,900)
launch_chrome() { # launch_chrome <profile-dir>: starts Chromium on $CDP_PORT
    if [ "$HEADED" = 1 ]; then
        "$CHROME" "${CHROME_HEADED_ARGS[@]}" --remote-debugging-port="$CDP_PORT" --user-data-dir="$1" about:blank >/dev/null 2>&1 &
    else
        "$CHROME" "${CHROME_HEADLESS_ARGS[@]}" --remote-debugging-port="$CDP_PORT" --user-data-dir="$1" about:blank >/dev/null 2>&1 &
    fi
}

cleanup() {
    pkill -f "user-data-dir=$TPROF" 2>/dev/null || true
    if [ -n "${CHROME_FRESH_PID:-}" ]; then
        kill -9 "$CHROME_FRESH_PID" 2>/dev/null || true
    fi
    if [ -n "${FRESH_PROF:-}" ]; then
        rm -rf "${FRESH_PROF:?}" 2>/dev/null || true
    fi
    for s in a b c; do
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
    # Main browser processes only: every Chromium child carries the debugging
    # port flag too, but only children have a --type flag, and children come
    # and go (renderers spawn lazily), so counting all processes is noisy.
    local pid count=0 cmd
    for pid in $(pgrep -f "remote-debugging-port=$CDP_PORT" 2>/dev/null); do
        kill -0 "$pid" 2>/dev/null || continue
        cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        case "$cmd" in
            *"--type="*) ;;
            *"remote-debugging-port=$CDP_PORT"*) count=$((count + 1)) ;;
        esac
    done
    printf '%s\n' "$count"
}

active_target() {
    local session="$1"
    "$BIN" --session "$session" tab list --json 2>/dev/null |
        python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print([t['targetId'] for t in d['tabs'] if t.get('active')][0])"
}

tab_urls() {
    local session="$1"
    "$BIN" --session "$session" tab list --json 2>/dev/null |
        python3 -c "import json,sys; [print(t['url']) for t in sorted(json.load(sys.stdin)['data']['tabs'], key=lambda t: t['url'])]"
}

reported_path() {
    python3 -c "import json,sys; print(json.load(sys.stdin)['data']['path'])"
}

binding_field() {
    local session="$1" field="$2"
    python3 -c "import json,sys; print(json.load(open('$SOCK_DIR/$session.target'))$field)"
}

wait_for_cdp() {
    for _ in $(seq 1 60); do
        curl -sf -m 2 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null && return 0
        sleep 0.5
    done
    return 1
}

wait_for_cdp_version() {
    # The HTTP endpoint answers before the browser serves CDP commands; wait
    # until Browser.getVersion answers so the first attach cannot mistake a
    # still-starting browser for a silent one.
    python3 - "$CDP_PORT" <<'EOF'
import base64, json, os, socket, struct, sys, time, urllib.request
port = sys.argv[1]
ver = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=5))
path = ver["webSocketDebuggerUrl"].split(f":{port}")[1]
for _ in range(60):
    try:
        s = socket.create_connection(("127.0.0.1", int(port)), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += s.recv(4096)
        data = json.dumps({"id": 1, "method": "Browser.getVersion"}).encode()
        m = os.urandom(4)
        s.sendall(bytes([0x81, 0x80 | len(data)]) + m + bytes(b ^ m[i % 4] for i, b in enumerate(data)))
        s.settimeout(5)
        buf = b""
        while len(buf) < 2:
            buf += s.recv(65536)
        ln, off = buf[1] & 0x7F, 2
        if ln == 126:
            ln = struct.unpack("!H", buf[2:4])[0]; off = 4
        if buf[1] & 0x80:
            off += 4
        while len(buf) < off + ln:
            buf += s.recv(65536)
        if b'"product"' in buf or b'"protocolVersion"' in buf:
            sys.exit(0)
        s.close()
    except Exception:
        pass
    time.sleep(0.5)
sys.exit(1)
EOF
}

# --- phase 1: shared browser + page ------------------------------------------
T0=$SECONDS
python3 "$SERVER_PY" &
SERVER_PID=$!
launch_chrome "$TPROF"
PHASE1_OK=0
wait_for_cdp &&
    curl -sf -m 2 "$PAGE_URL" >/dev/null && PHASE1_OK=1
if [ "$PHASE1_OK" -eq 1 ]; then S=pass; else S=fail; fi
check "one Chromium serves CDP and the test page" "$S" "$((SECONDS - T0))s"
CHROME_COUNT_START="$(chrome_count)"

# --- phase 2: AB-3 pinned own-window sessions ---------------------------------
T0=$SECONDS
"$BIN" --session a --cdp "$CDP_PORT" --pin-tab --download-path "$DL_A" \
    window new >/dev/null 2>&1
"$BIN" --session a --cdp "$CDP_PORT" --pin-tab --download-path "$DL_A" \
    open "$PAGE_URL" >/dev/null 2>&1
OPEN_A=$?
"$BIN" --session b --cdp "$CDP_PORT" --pin-tab --download-path "$DL_B" \
    window new >/dev/null 2>&1
"$BIN" --session b --cdp "$CDP_PORT" --pin-tab --download-path "$DL_B" \
    tab new "$PAGE_URL" >/dev/null 2>&1
OPEN_B=$?
if [ "$OPEN_A" -eq 0 ] && [ "$OPEN_B" -eq 0 ]; then S=pass; else S=fail; fi
check "sessions a and b attach pinned with own windows" "$S" "$((SECONDS - T0))s"

T0=$SECONDS
TARGET_A_BEFORE="$(active_target a)"
TARGET_B_BEFORE="$(active_target b)"
if [ -n "$TARGET_A_BEFORE" ] && [ -n "$TARGET_B_BEFORE" ] &&
    [ "$TARGET_A_BEFORE" != "$TARGET_B_BEFORE" ]; then S=pass; else S=fail; fi
check "a and b own different tabs" "$S" \
    "a=${TARGET_A_BEFORE:0:8} b=${TARGET_B_BEFORE:0:8} $((SECONDS - T0))s"

T0=$SECONDS
BID_A="$(binding_field a "['browser_id']" 2>/dev/null || true)"
BID_B="$(binding_field b "['browser_id']" 2>/dev/null || true)"
OWN_A="$(binding_field a "['own_window']" 2>/dev/null || true)"
OWN_B="$(binding_field b "['own_window']" 2>/dev/null || true)"
if [ -n "$BID_A" ] && [ "$BID_A" != "None" ] && [ "$BID_A" = "$BID_B" ] &&
    [ "$OWN_A" = "True" ] && [ "$OWN_B" = "True" ]; then S=pass; else S=fail; fi
check "bindings record one shared browser id and own windows" "$S" \
    "browser=${BID_A:0:8} $((SECONDS - T0))s"

# --- phase 3: AB-3 parallel downloads -----------------------------------------
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

# --- phase 4: AB-3 download from the session's own popup -----------------------
T0=$SECONDS
"$BIN" --session a --cdp "$CDP_PORT" click "#pop" >/dev/null 2>&1
POPUP_OK=0
for _ in $(seq 1 40); do
    tab_urls a 2>/dev/null | grep -q "popup.html" && { POPUP_OK=1; break; }
    sleep 0.5
done
if [ "$POPUP_OK" -eq 1 ]; then S=pass; else S=fail; fi
check "a adopts its popup" "$S" "$((SECONDS - T0))s"

T0=$SECONDS
POPUP_TARGET="$("$BIN" --session a tab list --json 2>/dev/null |
    python3 -c "import json,sys; print([t['targetId'] for t in json.load(sys.stdin)['data']['tabs'] if 'popup.html' in t.get('url','')][0])" 2>/dev/null || true)"
"$BIN" --session a --cdp "$CDP_PORT" tab "$POPUP_TARGET" >/dev/null 2>&1
"$BIN" --session a --cdp "$CDP_PORT" click "#dl-c" >/dev/null 2>&1
CLICK_C=$?
"$BIN" --session a --cdp "$CDP_PORT" wait --download --timeout 60000 --json \
    >"$TPROF/wait-c.json" 2>&1
WAIT_C=$?
PATH_C="$(reported_path <"$TPROF/wait-c.json" 2>/dev/null || true)"
POPUP_DL_OK=0
[ "$CLICK_C" -eq 0 ] && [ "$WAIT_C" -eq 0 ] &&
    [ "$PATH_C" = "$DL_A/file-c.bin" ] && [ -f "$DL_A/file-c.bin" ] &&
    [ ! -e "$DL_B/file-c.bin" ] &&
    [ "$(wc -c <"$DL_A/file-c.bin" | tr -d ' ')" = "65536" ] &&
    [ "$(head -c 1 "$DL_A/file-c.bin")" = "C" ] && POPUP_DL_OK=1
if [ "$POPUP_DL_OK" -eq 1 ]; then S=pass; else S=fail; fi
check "popup download lands in the popup owner's folder" "$S" \
    "c=$PATH_C $((SECONDS - T0))s"

# --- phase 5: AB-4 credentialed endpoint does not persist --------------------
T0=$SECONDS
"$BIN" --session c --cdp "http://user:secret@127.0.0.1:$CDP_PORT" --pin-tab \
    tab list >/dev/null 2>&1
ATTACH_C=$?
CDP_C="$(binding_field c "['cdp']" 2>/dev/null || true)"
if [ "$ATTACH_C" -eq 0 ] && [ "$CDP_C" = "None" ]; then S=pass; else S=fail; fi
check "credentialed endpoint attaches but does not persist" "$S" \
    "exit=$ATTACH_C cdp=$CDP_C $((SECONDS - T0))s"

# --- phase 6: AB-4 daemon death reattaches ------------------------------------
T0=$SECONDS
# Snapshot the live state right before the kill: phase 4 leaves session a
# on its popup tab, so the phase 2 target is stale by now.
TARGET_A_BEFORE="$(active_target a)"
URLS_A_BEFORE="$(tab_urls a 2>/dev/null || true)"
OWNED_BEFORE="$(binding_field a "['owned_targets']" 2>/dev/null || true)"
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
URLS_A_AFTER=""
[ "$REATTACH_EXIT" -eq 0 ] &&
    TARGET_A_AFTER="$(python3 -c "import json; d=json.load(open('$TPROF/reattach.json'))['data']; print([t['targetId'] for t in d['tabs'] if t.get('active')][0])" 2>/dev/null || true)" &&
    URLS_A_AFTER="$(tab_urls a 2>/dev/null || true)"
OWNED_AFTER="$(binding_field a "['owned_targets']" 2>/dev/null || true)"
CHROME_COUNT_AFTER="$(chrome_count)"
if [ "$REATTACH_EXIT" -eq 0 ] && [ "$TARGET_A_AFTER" = "$TARGET_A_BEFORE" ] &&
    [ "$URLS_A_AFTER" = "$URLS_A_BEFORE" ] && [ "$OWNED_AFTER" = "$OWNED_BEFORE" ] &&
    [ "$CHROME_COUNT_AFTER" = "$CHROME_COUNT_BEFORE" ]; then S=pass; else S=fail; fi
check "a reattaches to the same tab with ownership and no new browser" "$S" \
    "target=${TARGET_A_BEFORE:0:8}->${TARGET_A_AFTER:0:8} browsers=$CHROME_COUNT_BEFORE->$CHROME_COUNT_AFTER $((SECONDS - T0))s"

# --- phase 7: AB-4 fresh browser on the same port is refused ------------------
T0=$SECONDS
pkill -f "user-data-dir=$TPROF" 2>/dev/null || true
for _ in $(seq 1 20); do
    [ "$(chrome_count)" = "0" ] && break
    sleep 0.5
done
FRESH_PROF="$(mktemp -d)"
launch_chrome "$FRESH_PROF"
CHROME_FRESH_PID=$!
RESTART_OK=0
wait_for_cdp && wait_for_cdp_version && RESTART_OK=1
if [ "$RESTART_OK" -eq 1 ]; then S=pass; else S=fail; fi
check "fresh Chromium serves the same port" "$S" "$((SECONDS - T0))s"

CHROME_COUNT_FRESH="$(chrome_count)"
T0=$SECONDS
"$BIN" --session a tab list --json >"$TPROF/refused.json" 2>"$TPROF/refused.err"
REFUSED_EXIT=$?
REFUSED_OUT="$(cat "$TPROF/refused.json" "$TPROF/refused.err")"
sleep 2
CHROME_COUNT_AFTER_REFUSE="$(chrome_count)"
if [ "$REFUSED_EXIT" -ne 0 ] && [ "$CHROME_COUNT_AFTER_REFUSE" = "$CHROME_COUNT_FRESH" ] &&
    echo "$REFUSED_OUT" | grep -qi "different browser"; then S=pass; else S=fail; fi
check "reattach to a different browser refused, none started" "$S" \
    "exit=$REFUSED_EXIT browsers=$CHROME_COUNT_FRESH->$CHROME_COUNT_AFTER_REFUSE $((SECONDS - T0))s"
kill "$CHROME_FRESH_PID" 2>/dev/null || true
for _ in $(seq 1 20); do
    kill -0 "$CHROME_FRESH_PID" 2>/dev/null || break
    sleep 0.5
done
rm -rf "$FRESH_PROF"

# --- phase 8: AB-4 dead endpoint errors clearly -------------------------------
T0=$SECONDS
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

#!/bin/bash
# play — test suite
# Covers: arg parsing, server startup, audio serving, directory mode, edge cases
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAY="$SCRIPT_DIR/play"
PASS=0
FAIL=0
TOTAL=0

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; DIM='\033[2m'; RESET='\033[0m'

pass() { ((PASS++)); ((TOTAL++)); printf "${GREEN}  ✓${RESET} %s\n" "$1"; }
fail() { ((FAIL++)); ((TOTAL++)); printf "${RED}  ✗${RESET} %s — %s\n" "$1" "$2"; }
section() { printf "\n${YELLOW}▸ %s${RESET}\n" "$1"; }

# Start a server, run tests, kill it. Usage: with_server <file> <port> <extra_args...>
start_server() {
  $PLAY "$1" -p "$2" --no-open ${3:+"$3" "$4"} &>/dev/null &
  echo $!
}

cleanup() {
  pkill -f "bun.*server.ts" 2>/dev/null || true
  rm -rf "$TMPDIR/play_test_"* 2>/dev/null || true
}
trap cleanup EXIT

# Create test fixtures
FIXTURES="$TMPDIR/play_test_$$"
mkdir -p "$FIXTURES/subdir" "$FIXTURES/path with spaces"

printf "${YELLOW}play${RESET} test suite\n"
printf "${DIM}generating fixtures...${RESET}\n"

ffmpeg -y -f lavfi -i "sine=frequency=440:duration=2" -q:a 9 "$FIXTURES/test.mp3" 2>/dev/null
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=2" "$FIXTURES/test.m4a" 2>/dev/null
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=2" "$FIXTURES/test.wav" 2>/dev/null
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=2" "$FIXTURES/会议录音.m4a" 2>/dev/null
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=2" "$FIXTURES/subdir/nested.mp3" 2>/dev/null
cp "$FIXTURES/test.mp3" "$FIXTURES/path with spaces/file (1).mp3"
touch "$FIXTURES/empty.mp3"
echo "not audio" > "$FIXTURES/readme.txt"
echo "not audio" > "$FIXTURES/data.json"

printf "${DIM}fixtures: $FIXTURES${RESET}\n"

# ─────────────────────────────────────────────
section "CLI argument parsing"

$PLAY --help 2>&1 | grep -q "browser-based audio player" && pass "--help shows usage" || fail "--help shows usage" "no output"
$PLAY 2>&1 | grep -qi "usage" && pass "no args shows usage error" || fail "no args shows usage error" "unexpected output"
$PLAY /tmp/nonexistent_xyz_$$.mp3 2>&1 || true; pass "nonexistent file exits with error"

# ─────────────────────────────────────────────
section "Server startup & audio serving"

PORT=$((10000 + RANDOM % 50000))
$PLAY "$FIXTURES/test.mp3" -s 2.5 -p $PORT --no-open &
PID=$!
sleep 2

kill -0 $PID 2>/dev/null && pass "server starts" || fail "server starts" "process died"

curl -sf "http://localhost:$PORT/" >/dev/null && pass "HTML returns 200" || fail "HTML returns 200" "failed"
curl -s "http://localhost:$PORT/" | grep -q 'speed: 2.5' && pass "speed injected" || fail "speed injected" "not found"
curl -s "http://localhost:$PORT/" | grep -q 'test.mp3' && pass "filename injected" || fail "filename injected" "not found"

CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/audio")
[[ "$CODE" == "200" ]] && pass "audio returns 200" || fail "audio returns 200" "got $CODE"

curl -sI "http://localhost:$PORT/audio" | grep -qi "audio/mpeg" && pass "Content-Type: audio/mpeg" || fail "Content-Type" "wrong type"
curl -sI "http://localhost:$PORT/audio" | grep -qi "accept-ranges: bytes" && pass "Accept-Ranges header" || fail "Accept-Ranges" "missing"

CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Range: bytes=0-1023" "http://localhost:$PORT/audio")
[[ "$CODE" == "206" ]] && pass "range request → 206" || fail "range request" "got $CODE"

curl -sI -H "Range: bytes=0-1023" "http://localhost:$PORT/audio" | grep -qi "bytes 0-1023" && pass "Content-Range correct" || fail "Content-Range" "wrong"

CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/nope")
[[ "$CODE" == "404" ]] && pass "unknown route → 404" || fail "404 route" "got $CODE"

kill $PID 2>/dev/null; wait $PID 2>/dev/null || true

# ─────────────────────────────────────────────
section "Chinese filename"

P=$((10000 + RANDOM % 50000))
PID=$(start_server "$FIXTURES/会议录音.m4a" $P)
sleep 2

curl -s "http://localhost:$P/" | grep -q '会议录音' && pass "Chinese name in HTML" || fail "Chinese name" "not found"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$P/audio")
[[ "$CODE" == "200" ]] && pass "Chinese-named file serves" || fail "Chinese file" "got $CODE"

kill $PID 2>/dev/null; wait $PID 2>/dev/null || true

# ─────────────────────────────────────────────
section "MIME type detection"

test_mime() {
  local file="$1" expected="$2" p=$((10000 + RANDOM % 50000))
  local pid=$(start_server "$FIXTURES/$file" $p)
  sleep 1.5
  local got=$(curl -sI "http://localhost:$p/audio" | grep -i content-type | tr -d '\r')
  echo "$got" | grep -qi "$expected" && pass "$file → $expected" || fail "$file MIME" "got: $got"
  kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
}

test_mime "test.mp3" "audio/mpeg"
test_mime "test.m4a" "audio/mp4"
test_mime "test.wav" "audio/wav"

# ─────────────────────────────────────────────
section "Directory scanning"

FOUND=$(find "$FIXTURES" -maxdepth 3 -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.wav' \) | wc -l | tr -d ' ')
[[ "$FOUND" -ge 5 ]] && pass "finds $FOUND audio files" || fail "audio scan" "expected >=5, got $FOUND"

NON=$(find "$FIXTURES" -maxdepth 3 -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.wav' \) | grep -c '\.txt\|\.json' || true)
[[ "$NON" -eq 0 ]] && pass "non-audio excluded" || fail "non-audio excluded" "$NON found"

find "$FIXTURES" -maxdepth 3 -type f -iname '*.mp3' | grep -q 'subdir/nested' && pass "nested files found" || fail "nested" "not found"

# ─────────────────────────────────────────────
section "Edge cases & chaos"

# Zero-byte file
P=$((10000 + RANDOM % 50000))
PID=$(start_server "$FIXTURES/empty.mp3" $P)
sleep 1.5
LEN=$(curl -sI "http://localhost:$P/audio" | grep -i content-length | awk '{print $2}' | tr -d '\r')
[[ "$LEN" == "0" ]] && pass "zero-byte file → Content-Length: 0" || fail "zero-byte" "len=$LEN"
kill $PID 2>/dev/null; wait $PID 2>/dev/null || true

# Extreme speed
P=$((10000 + RANDOM % 50000))
PID=$(start_server "$FIXTURES/test.mp3" $P -s 0.1)
sleep 1.5
curl -s "http://localhost:$P/" | grep -q 'speed: 0.1' && pass "speed 0.1x accepted" || fail "speed 0.1x" "not injected"
kill $PID 2>/dev/null; wait $PID 2>/dev/null || true

# Path with spaces and parens
P=$((10000 + RANDOM % 50000))
$PLAY "$FIXTURES/path with spaces/file (1).mp3" -p $P --no-open &>/dev/null &
PID=$!; sleep 1.5
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$P/audio")
[[ "$CODE" == "200" ]] && pass "spaces + parens in path" || fail "special path" "got $CODE"
kill $PID 2>/dev/null; wait $PID 2>/dev/null || true

# Concurrent range requests
P=$((10000 + RANDOM % 50000))
PID=$(start_server "$FIXTURES/test.mp3" $P)
sleep 1.5
ALL_OK=true
for off in 0 1024 2048 4096; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Range: bytes=$off-$((off+1023))" "http://localhost:$P/audio")
  [[ "$code" != "206" ]] && ALL_OK=false
done
$ALL_OK && pass "4 concurrent range requests → 206" || fail "concurrent ranges" "some failed"
kill $PID 2>/dev/null; wait $PID 2>/dev/null || true

# Rapid start/stop (stress)
STRESS_OK=true
for i in 1 2 3; do
  P=$((10000 + RANDOM % 50000))
  PID=$(start_server "$FIXTURES/test.mp3" $P)
  sleep 0.8
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$P/" 2>/dev/null || echo "000")
  [[ "$CODE" != "200" ]] && STRESS_OK=false
  kill $PID 2>/dev/null; wait $PID 2>/dev/null || true
done
$STRESS_OK && pass "rapid start/stop ×3" || fail "rapid start/stop" "some failed"

# ─────────────────────────────────────────────
printf "\n${DIM}─────────────────────────────────────${RESET}\n"
if [[ $FAIL -eq 0 ]]; then
  printf "${GREEN}All $TOTAL tests passed${RESET}\n\n"
else
  printf "${RED}$FAIL/$TOTAL tests failed${RESET}\n\n"
fi
exit $FAIL

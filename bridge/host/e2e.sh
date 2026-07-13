#!/bin/bash
# e2e.sh — headless proof of the helper↔UDS chain (plan A5), no browser, no Zodl:
#   [framed stdin message] → zodl-bridge-host → UDS → mock-zodl → ack → stdout
# Exits 0 only if the mock received the request AND the host acked "received",
# plus a foreign-caller message is refused.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d /tmp/zodl-bridge-e2e.XXXXXX)"
SOCK="$WORK/bridge.sock"
EXT_ID="nginegnmdihpegemkajmjjeimigdkjma"
trap 'kill $MOCK_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "building…"
(cd "$SCRIPT_DIR" && swift build >/dev/null)
BIN="$SCRIPT_DIR/.build/debug"

# Scratch install: binary + config pointing at the temp socket.
cp "$BIN/zodl-bridge-host" "$WORK/"
cat > "$WORK/bridge-config.json" <<EOF
{"allowedExtensionIDs": ["$EXT_ID"], "socketPath": "$SOCK"}
EOF

"$BIN/mock-zodl" "$SOCK" > "$WORK/mock.log" &
MOCK_PID=$!
for _ in $(seq 1 20); do [[ -S "$SOCK" ]] && break; sleep 0.1; done
[[ -S "$SOCK" ]] || { echo "FAIL: mock-zodl never bound $SOCK"; exit 1; }

frame() {
    python3 -c "
import struct, sys
body = sys.argv[1].encode()
sys.stdout.buffer.write(struct.pack('<I', len(body)) + body)
" "$1"
}
MSG='{"v":1,"id":"E2E-0001","type":"payRequest","uri":"zcash:u1e2etest?amount=0.001","origin":"https://shop.example","requestSrc":null}'

echo "→ happy path (our extension id)…"
ACK=$(frame "$MSG" | "$WORK/zodl-bridge-host" "chrome-extension://$EXT_ID/" | tail -c +5)
echo "  ack: $ACK"
[[ "$ACK" == *'"status":"received"'* ]] || { echo "FAIL: expected received"; exit 1; }
grep -q "zcash:u1e2etest" "$WORK/mock.log" || { echo "FAIL: mock never saw the request"; exit 1; }
echo "  mock-zodl log: $(grep REQUEST "$WORK/mock.log" | head -1)"

echo "→ foreign caller (must be refused)…"
# The helper refuses BEFORE reading stdin (deliberate), so the writer's pipe
# breaks — tolerate that; the assertion is on the ack.
ACK2=$( (frame "$MSG" 2>/dev/null || true) | "$WORK/zodl-bridge-host" "chrome-extension://qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq/" | tail -c +5)
echo "  ack: $ACK2"
[[ "$ACK2" == *'"caller-not-allowed"'* ]] || { echo "FAIL: foreign caller not refused"; exit 1; }
[[ $(grep -c REQUEST "$WORK/mock.log") -eq 1 ]] || { echo "FAIL: foreign request reached the socket"; exit 1; }

echo "E2E PASS: pinned chain delivers, foreign caller refused."

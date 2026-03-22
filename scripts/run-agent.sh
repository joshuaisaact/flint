#!/bin/bash
# Simulate the agent pipeline: acquire VM, reproduce bug, patch, validate, release.
# Requires: pool running (see setup-yoga-vm.sh step 4)
#
# Usage: ./scripts/run-agent.sh

set -euo pipefail

POOL_SOCK="/tmp/flint-yoga-pool.sock"

echo "=== Agent Pipeline Simulation ==="

# 1. Acquire a VM with 10-minute safety timeout
echo "--- Acquiring VM ---"
ACQUIRE=$(curl -sf --unix-socket "$POOL_SOCK" http://localhost/pool/acquire \
    -d '{"timeout_ms": 600000}')
echo "$ACQUIRE"

VM_ID=$(echo "$ACQUIRE" | grep -o '"id":[0-9]*' | cut -d: -f2)
API_SOCK=$(echo "$ACQUIRE" | grep -o '"api_sock":"[^"]*"' | cut -d'"' -f4)

echo "Got VM $VM_ID at $API_SOCK"

# Helper to run commands in the guest
exec_guest() {
    local cmd="$1"
    local timeout="${2:-30}"
    curl -sf --unix-socket "$API_SOCK" http://localhost/sandbox/exec \
        -d "{\"cmd\":\"$cmd\",\"timeout\":$timeout}"
}

# Helper to decode base64 output
decode_output() {
    echo "$1" | grep -o '"stdout":"[^"]*"' | cut -d'"' -f4 | base64 -d 2>/dev/null
}

# 2. Wait for guest to be ready
echo "--- Checking guest health ---"
for i in $(seq 1 30); do
    HEALTH=$(exec_guest "curl -sf http://localhost:3000/api/health" 5 2>/dev/null) || true
    if echo "$HEALTH" | grep -q '"exit_code":0'; then
        echo "Guest app is healthy!"
        decode_output "$HEALTH"
        break
    fi
    echo "  waiting... ($i/30)"
    sleep 2
done

# 3. Reproduce a bug: hit an endpoint
echo ""
echo "--- Step 3: Reproduce bug (hit API endpoint) ---"
RESULT=$(exec_guest "curl -sf http://localhost:3000/api/health" 10)
echo "Response:"
decode_output "$RESULT"

# 4. Query logs
echo ""
echo "--- Step 4: Query logs ---"
LOGS=$(exec_guest "cat /var/log/app.log | tail -20" 10)
echo "Last 20 lines of app log:"
decode_output "$LOGS"

# 5. Patch a source file
echo ""
echo "--- Step 5: Patch source code ---"
# Example: add a custom header to the health endpoint
PATCH='import { Elysia } from "elysia";\n\nexport const healthRoute = new Elysia().get("/api/health/patched", () => ({\n  status: "ok",\n  patched: true,\n  timestamp: new Date().toISOString()\n}));'
PATCH_B64=$(echo -e "$PATCH" | base64 -w0)

curl -sf --unix-socket "$API_SOCK" http://localhost/sandbox/write \
    -d "{\"path\":\"/app/backend/src/routes/health-patched.route.ts\",\"data\":\"$PATCH_B64\",\"mode\":420}"
echo "Wrote patched route"

# 6. Restart the app
echo ""
echo "--- Step 6: Restart app ---"
exec_guest "pkill -f 'bun src/index.ts'; sleep 1; cd /app/backend && /bin/bun src/index.ts > /var/log/app.log 2>&1 &" 10
sleep 3

# 7. Validate the fix
echo ""
echo "--- Step 7: Validate fix ---"
RESULT=$(exec_guest "curl -sf http://localhost:3000/api/health" 10)
echo "Health check after patch:"
decode_output "$RESULT"

# 8. Release the VM
echo ""
echo "--- Releasing VM $VM_ID ---"
curl -sf --unix-socket "$POOL_SOCK" http://localhost/pool/release \
    -d "{\"id\":$VM_ID}"
echo "Released."

echo ""
echo "=== Pipeline complete ==="

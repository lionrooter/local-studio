#!/usr/bin/env bash
# fleet-deploy.sh — Deploy local-studio controller to a fleet box via SSH.
#
# Usage: fleet-deploy.sh <machineId> [--api-key <key>]
#
# Steps:
#   1. SSH to the target machine (via Tailscale hostname from fleet-overnight API)
#   2. Clone/update the lionrooter/local-studio fork (pinned branch)
#   3. Generate .env from fleet-recipes.json match
#   4. Install dependencies (bun install)
#   5. Create LaunchAgent (macOS) or systemd service (Linux) for the controller
#
# Prerequisites:
#   - SSH access to the target machine (Tailscale)
#   - bun installed on the target machine
#   - For vLLM backend: NVIDIA GPU + CUDA toolkit
#   - For MLX backend: Apple Silicon Mac
set -euo pipefail

MACHINE_ID="${1:?Usage: fleet-deploy.sh <machineId> [--api-key <key>]}"
API_KEY=""
if [[ "${2:-}" == "--api-key" ]]; then
  API_KEY="${3:?--api-key requires a value}"
fi

REPO_URL="https://github.com/lionrooter/local-studio.git"
BRANCH="lionroot-pinned-v1.51.5"
CLONE_DIR="$HOME/local-studio"
LAUNCH_AGENT_LABEL="ai.lionroot.local-studio-controller"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECIPES="$SCRIPT_DIR/fleet-recipes.json"

# Resolve Tailscale hostname from the fleet-overnight API
resolve_host() {
  local mid="$1"
  curl -sf -m 5 http://127.0.0.1:3007/api/fleet-overnight/status 2>/dev/null \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
m = next((x for x in d.get('machines',[]) if x.get('id') == sys.argv[1]), None)
if m and m.get('host'): print(m['host'])
else: sys.exit(1)
" "$mid" 2>/dev/null
}

# Resolve backend from recipes
resolve_backend() {
  local mid="$1"
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
for r in d.get('recipes', []):
    match = r.get('match', {})
    ids = match.get('machineId', [])
    if isinstance(ids, str): ids = [ids]
    if sys.argv[2] in ids:
        print(r.get('backend', 'ollama'))
        sys.exit(0)
print(d.get('defaults', {}).get('backend', 'ollama'))
" "$RECIPES" "$mid" 2>/dev/null || echo "ollama"
}

HOST=$(resolve_host "$MACHINE_ID") || {
  echo "ERROR: Could not resolve host for machine '$MACHINE_ID' via fleet-overnight API"
  exit 1
}
BACKEND=$(resolve_backend "$MACHINE_ID")
echo "Deploying local-studio to $MACHINE_ID ($HOST) with backend: $BACKEND"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

# Step 1: Clone/update the fork on the target
echo "→ Cloning/updating fork on $HOST..."
ssh -n "${SSH_OPTS[@]}" "$HOST" "
  if [ -d $CLONE_DIR/.git ]; then
    cd $CLONE_DIR && git fetch origin && git checkout $BRANCH && git reset --hard origin/$BRANCH
  else
    git clone --branch $BRANCH --depth 1 $REPO_URL $CLONE_DIR
  fi
" 2>&1

# Step 2: Generate .env
echo "→ Generating .env..."
API_KEY_VAL="${API_KEY:-$(openssl rand -hex 24 2>/dev/null || echo 'changeme')}"
ssh -n "${SSH_OPTS[@]}" "$HOST" "cat > $CLONE_DIR/.env <<ENVEOF
LOCAL_STUDIO_HOST=0.0.0.0
LOCAL_STUDIO_PORT=8080
LOCAL_STUDIO_API_KEY=$API_KEY_VAL
LOCAL_STUDIO_DEFAULT_BACKEND=$BACKEND
ENVEOF
" 2>&1
echo "  API key: ${API_KEY_VAL:0:8}... (saved in .env on $HOST)"

# Step 3: Install dependencies
echo "→ Installing dependencies..."
ssh -n "${SSH_OPTS[@]}" "$HOST" "cd $CLONE_DIR && bun install" 2>&1 | tail -5

# Step 4: Create LaunchAgent (macOS) or systemd service (Linux)
echo "→ Creating system service..."
ssh -n "${SSH_OPTS[@]}" "$HOST" "
  if [ \"\$(uname)\" = \"Darwin\" ]; then
    mkdir -p ~/Library/LaunchAgents
    cat > ~/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist <<PLISTEOF
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key><string>${LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>cd $CLONE_DIR && exec bun run controller</string>
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$CLONE_DIR/controller.log</string>
  <key>StandardErrorPath</key><string>$CLONE_DIR/controller.err.log</string>
</dict>
</plist>
PLISTEOF
    launchctl bootstrap gui/\\\$(id -u) ~/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist 2>/dev/null || true
    echo 'LaunchAgent created + loaded'
  else
    echo 'Linux systemd service creation not yet implemented — start manually: cd $CLONE_DIR && bun run controller'
  fi
" 2>&1

echo ""
echo "✓ Deployed local-studio to $MACHINE_ID ($HOST)"
echo "  Controller: http://$HOST:8080"
echo "  Backend: $BACKEND"
echo "  API key: ${API_KEY_VAL:0:8}..."
echo ""
echo "Next: update ~/.openclaw/local-studio-controllers.json with the API key for $MACHINE_ID"

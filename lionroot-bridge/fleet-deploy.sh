#!/usr/bin/env bash
# fleet-deploy.sh — Deploy local-studio controller to a fleet box via SSH.
#
# Usage: fleet-deploy.sh <machineId> [--api-key <key>]
#
# Uses `ssh ... bash -s` heredoc pattern so ALL variables expand on the remote
# side (avoids $HOME / escaping bugs). Passes params as positional args.
set -euo pipefail

MACHINE_ID="${1:?Usage: fleet-deploy.sh <machineId> [--api-key <key>]}"
API_KEY=""
if [[ "${2:-}" == "--api-key" ]]; then
  API_KEY="${3:?--api-key requires a value}"
fi

REPO_URL="https://github.com/lionrooter/local-studio.git"
BRANCH="lionroot-pinned-v1.51.5"
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
API_KEY_VAL="${API_KEY:-$(openssl rand -hex 24 2>/dev/null || echo "changeme")}"

echo "Deploying local-studio to $MACHINE_ID ($HOST) with backend: $BACKEND"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

# Run entire remote setup via bash -s heredoc — all vars expand on the remote.
# Args: $1=REPO_URL $2=BRANCH $3=API_KEY $4=BACKEND $5=LABEL
ssh "${SSH_OPTS[@]}" "$HOST" bash -s "$REPO_URL" "$BRANCH" "$API_KEY_VAL" "$BACKEND" "$LAUNCH_AGENT_LABEL" <<'REMOTE'
set -euo pipefail
REPO_URL="$1"; BRANCH="$2"; API_KEY="$3"; BACKEND="$4"; LABEL="$5"
CLONE_DIR="$HOME/local-studio"

echo "→ Clone/update fork..."
if [ -d "$CLONE_DIR/.git" ]; then
  cd "$CLONE_DIR" && git fetch origin && git checkout "$BRANCH" && git reset --hard "origin/$BRANCH"
else
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$CLONE_DIR"
fi

echo "→ Generate .env..."
cat > "$CLONE_DIR/.env" <<ENVEOF
LOCAL_STUDIO_HOST=0.0.0.0
LOCAL_STUDIO_PORT=8080
LOCAL_STUDIO_API_KEY=$API_KEY
LOCAL_STUDIO_DEFAULT_BACKEND=$BACKEND
ENVEOF

echo "→ Install unzip (required by bun installer)..."
if ! command -v unzip >/dev/null 2>&1; then
  apt-get update -qq 2>/dev/null && apt-get install -y -qq unzip 2>&1 | tail -2 || true
fi

echo "→ Check bun..."
if ! command -v bun >/dev/null 2>&1; then
  echo "  bun not found — installing..."
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
fi

echo "→ Install dependencies..."
cd "$CLONE_DIR" && bun install

echo "→ Create system service..."
if [ "$(uname)" = "Darwin" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$HOME/Library/LaunchAgents/${LABEL}.plist" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>PLACEHOLDER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>cd PLACEHOLDER_CLONE && exec bun run controller</string>
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>PLACEHOLDER_CLONE/controller.log</string>
  <key>StandardErrorPath</key><string>PLACEHOLDER_CLONE/controller.err.log</string>
</dict>
</plist>
PLISTEOF
  # Replace placeholders (can't use $ in the quoted heredoc above)
  sed -i.bak "s|PLACEHOLDER_LABEL|$LABEL|g; s|PLACEHOLDER_CLONE|$CLONE_DIR|g" "$HOME/Library/LaunchAgents/${LABEL}.plist"
  rm -f "$HOME/Library/LaunchAgents/${LABEL}.plist.bak"
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/${LABEL}.plist" 2>/dev/null || true
  echo "  LaunchAgent created + loaded"
else
  # Linux: systemd user service
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/${LABEL}.service" <<'SVCEOF'
[Unit]
Description=Local Studio Controller
After=network.target

[Service]
Type=simple
WorkingDirectory=PLACEHOLDER_CLONE
ExecStart=%h/.bun/bin/bun run controller
Restart=always
RestartSec=5
Environment=LOCAL_STUDIO_HOST=0.0.0.0
Environment=LOCAL_STUDIO_PORT=8080

[Install]
WantedBy=default.target
SVCEOF
  sed -i "s|PLACEHOLDER_CLONE|$CLONE_DIR|g" "$HOME/.config/systemd/user/${LABEL}.service"
  systemctl --user daemon-reload
  systemctl --user enable --now "${LABEL}.service" 2>/dev/null || echo "  systemd service created (start manually if needed)"
  echo "  systemd service created + started"
fi

echo "→ Verify controller is responding..."
sleep 3
if curl -sf -m 5 http://127.0.0.1:8080/api/system >/dev/null 2>&1; then
  echo "  Controller is UP on :8080"
else
  echo "  Controller not yet responding (may still be starting — check $CLONE_DIR/controller.err.log)"
fi

echo "✓ Deploy complete on $(hostname)"
REMOTE

echo ""
echo "✓ Deployed local-studio to $MACHINE_ID ($HOST)"
echo "  Controller: http://$HOST:8080"
echo "  Backend: $BACKEND"
echo "  API key: ${API_KEY_VAL:0:8}..."
echo ""
echo "Next: update ~/.openclaw/local-studio-controllers.json with the API key for $MACHINE_ID"

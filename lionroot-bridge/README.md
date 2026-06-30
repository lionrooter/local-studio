# Lionroot Bridge — Fleet Integration for Local Studio

This module bridges [Local Studio](https://github.com/sybil-solutions/local-studio)
with the Lionroot fleet system. It provides:

- **fleet-recipes.json** — Model recipes per fleet machine (which models to launch
  on which hardware backend: vLLM for NVIDIA, MLX for Apple Silicon)
- **fleet-deploy.sh** — SSH deploy script: clones the fork, generates .env, installs
  deps, starts the controller as a system service on the target box
- **fleet-sync-config.sh** — Reads fleet machine configs from the Lionroot repo +
  generates `local-studio-controllers.json` for the dashboard telemetry API

## Architecture

```
Lionroot Command Post (dashboard :3007)
  └── /api/fleet-orchestrator/local-studio-telemetry
       └── local-studio-bridge.ts (probe + enrich)
            └── HTTP GET http://<box>:8080/api/system
                 └── Local Studio controller (per-box, :8080)
                      ├── vLLM backend (NVIDIA GPUs)
                      ├── MLX backend (Apple Silicon)
                      └── ollama backend (fallback)
```

## Deployment

```bash
# Deploy to a fleet box (from lionheart):
bash lionroot-bridge/fleet-deploy.sh dadspowerspec

# Sync fleet config (generates controllers.json):
bash lionroot-bridge/fleet-sync-config.sh
```

## Pinned Version

This fork is pinned to `v1.51.5` on branch `lionroot-pinned-v1.51.5`.
Lionroot-specific changes live in `lionroot-bridge/` only — the upstream
controller, CLI, frontend, and shared code are unmodified.

## Config

Each fleet box runs the controller with:
- `LOCAL_STUDIO_HOST=0.0.0.0` (reachable via Tailscale)
- `LOCAL_STUDIO_PORT=8080`
- `LOCAL_STUDIO_API_KEY` set (required for non-loopback)
- Backend selected by hardware: vLLM (NVIDIA), MLX (Apple Silicon), ollama (fallback)

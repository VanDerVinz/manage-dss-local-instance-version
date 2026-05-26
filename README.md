# upgrade_local_dss_instance

Upgrades all local Dataiku DSS nodes to the latest public release in one command. It:

1. Fetches the latest version number from `downloads.dataiku.com`
2. Downloads and extracts the installer
3. Stops → upgrades → restarts each node
4. Rebuilds the Docker base image (`linux/amd64`) on each node
5. Cleans up old installer files

Works on macOS and Linux. On Apple Silicon Macs it automatically runs under Rosetta (`x86_64`).

---

## Prerequisites

- `curl` and `tar` (standard on macOS/Linux)
- Docker (only needed for the Docker image rebuild step)
- Dataiku DSS already installed on at least one local node

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/VanDerVinz/upgrade_local_dss_instance.git
cd upgrade_local_dss_instance

# 2. Run (uses built-in defaults — edit the CONFIGURATION section in the script for permanent changes)
bash upgrade_dss.sh
```

---

## Configuration

Two variables control the script. Both have built-in defaults you can edit directly in the `CONFIGURATION` block at the top of `upgrade_dss.sh`, or override at runtime via env vars — no file editing needed.

| Variable | What it controls | Default |
|---|---|---|
| `DSS_VERSIONS_DIR` | Directory where the installer is downloaded and extracted | `~/dss/dss_13/dss_versions` |
| `DSS_NODES_LIST` | Colon-separated list of node directories to upgrade, in order | Four nodes under `~/dss/dss_13/` |

### Override examples

```bash
# Custom versions directory
DSS_VERSIONS_DIR=~/my/dss/installers bash upgrade_dss.sh

# Custom node list (colon-separated, full paths)
DSS_NODES_LIST="${HOME}/dss/design:${HOME}/dss/automation" bash upgrade_dss.sh

# Both at once
DSS_VERSIONS_DIR=~/installers \
DSS_NODES_LIST="${HOME}/dss/design:${HOME}/dss/automation" \
bash upgrade_dss.sh
```

Paths that don't exist are silently skipped, so it's safe to leave extra nodes in the list.

---

## Raycast

Add the script to your [Raycast Scripts Directory](https://manual.raycast.com/script-commands) — the metadata headers at the top of the file are picked up automatically. The script appears as **"Upgrade DSS"** in the `Dataiku DSS` package.

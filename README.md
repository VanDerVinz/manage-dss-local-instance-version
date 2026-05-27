# upgrade_local_dss_instance

Manage local Dataiku DSS installations from a single script: upgrade existing nodes, install specific versions, and remove installations you no longer need.

Works on macOS and Linux. On Apple Silicon Macs it automatically runs under Rosetta (`x86_64`).

---

## Prerequisites

- `curl` and `tar` (standard on macOS/Linux)
- Docker (only needed for the Docker image rebuild step in `upgrade`)
- Dataiku DSS already installed for `upgrade`; not required for `install`

---

## Quick start

```bash
git clone https://github.com/VanDerVinz/manage-dss-local-instance-version.git
cd upgrade_local_dss_instance
bash dss.sh <command>
```

---

## Commands

### `upgrade`

Upgrades all configured nodes to the latest public DSS release. For each node it stops DSS, runs the upgrade installer, restarts, and rebuilds the Docker base image. Old installer files are cleaned up at the end.

```bash
bash dss.sh upgrade
```

### `install <version>`

Downloads and installs a specific DSS version to its own directory (`~/dss/dss_<version>`). This is a fresh install — it does not touch any existing node.

```bash
bash dss.sh install 14.5.1
```

The instance is not started automatically. Once the installer finishes it prints the start/stop commands.

### `remove <version>`

Stops DSS (if running) and deletes the installation directory for a given version.

```bash
bash dss.sh remove 14.5.1
```

---

## Configuration

All variables have built-in defaults. Edit them in the `CONFIGURATION` block at the top of `dss.sh`, or pass them as env vars at runtime — no permanent file editing needed.

| Variable | What it controls | Default |
|---|---|---|
| `DSS_BASE_DIR` | Base directory for new installs | `~/dss` |
| `DSS_VERSIONS_DIR` | Where installers are downloaded and extracted | `~/dss/installers` |
| `DSS_INSTALL_PORT` | TCP port used when installing a new instance | `10000` |
| `DSS_NODES_LIST` | Colon-separated node paths for `upgrade`, in dependency order | Four nodes under `~/dss/dss_13/` |

### Override examples

```bash
# Upgrade with a custom node list
DSS_NODES_LIST="${HOME}/dss/design:${HOME}/dss/automation" bash dss.sh upgrade

# Install to a custom base directory on a specific port
DSS_BASE_DIR=~/my/dss DSS_INSTALL_PORT=10001 bash dss.sh install 14.5.1

# Remove an install from a custom base directory
DSS_BASE_DIR=~/my/dss bash dss.sh remove 14.5.1
```

Paths that don't exist are silently skipped in `upgrade`, so it's safe to leave extra nodes in the list.

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

The instance starts automatically once installed.

### `remove <version>`

Stops DSS (if running) and deletes the installation directory for a given version.

```bash
bash dss.sh remove 14.5.1
```

---

## Configuration

Open `dss.sh` and edit the `CONFIGURATION` block at the top — that's the only section you need to touch.

| Variable | What it controls | Default |
|---|---|---|
| `DSS_BASE_DIR` | Where new DSS installations are created | `~/dss` |
| `DSS_VERSIONS_DIR` | Where installers are downloaded | `~/dss/installers` |
| `DSS_INSTALL_PORT` | TCP port for new installations | `10000` (auto-increments if taken) |
| `DSS_NODES` | List of node directories to upgrade, in order | Four nodes under `~/dss/dss_13/` |

Paths in `DSS_NODES` that don't exist are silently skipped, so it's safe to leave extras in the list.

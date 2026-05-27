#!/bin/bash
#
# dss.sh — Manage local Dataiku DSS installations.
#
# Usage:
#   bash dss.sh upgrade              Upgrade all configured nodes to the latest release
#   bash dss.sh install <version>    Install a specific DSS version to its own directory
#   bash dss.sh remove  <version>    Stop and remove a DSS installation
#
# Edit the CONFIGURATION section below, or override any value via env vars.

# ── Architecture: ensure we run under x86_64 (Intel/Rosetta) ─────────────────
if [[ "$(uname -m)" != "x86_64" ]]; then
  exec /usr/bin/arch -x86_64 /bin/bash "$0" "$@"
fi

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION — edit the defaults below, or override any value via env vars
# before running (env vars take precedence over the defaults here).
# ═══════════════════════════════════════════════════════════════════════════════

# Base directory where new DSS installations are created.
# Override: DSS_BASE_DIR=~/my/dss bash dss.sh install 14.5.1
DSS_BASE_DIR="${DSS_BASE_DIR:-${HOME}/dss}"

# Directory where DSS installers are downloaded and extracted.
# Override: DSS_VERSIONS_DIR=~/my/installers bash dss.sh upgrade
DSS_VERSIONS_DIR="${DSS_VERSIONS_DIR:-${DSS_BASE_DIR}/installers}"

# TCP port used when installing a new DSS instance (install command only).
# Override: DSS_INSTALL_PORT=10001 bash dss.sh install 14.5.1
DSS_INSTALL_PORT="${DSS_INSTALL_PORT:-10000}"

# Nodes to upgrade, in dependency order (upgrade command only).
# Paths that don't exist are skipped automatically.
# Override via a colon-separated list:
#   DSS_NODES_LIST="${HOME}/dss/node1:${HOME}/dss/node2" bash dss.sh upgrade
if [[ -n "${DSS_NODES_LIST:-}" ]]; then
  IFS=':' read -ra DSS_NODES <<< "${DSS_NODES_LIST}"
else
  DSS_NODES=(
    "${HOME}/dss/dss_13/design_intel_v6"
    "${HOME}/dss/dss_13/deployer"
    "${HOME}/dss/dss_13/automation_prod"
    "${HOME}/dss/dss_13/automation_test"
  )
fi

# ═══════════════════════════════════════════════════════════════════════════════

BASE_URL="https://downloads.dataiku.com/public/dss"

case "$(uname -s)" in
  Darwin) PLATFORM="osx" ;;
  Linux)  PLATFORM="linux" ;;
  *)      echo "❌ Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "❌ ERROR: $*" >&2; exit 1; }

# Sets AVAILABLE_PORT to the first free TCP port at or above the given port.
AVAILABLE_PORT=""
find_available_port() {
  local port="$1"
  for (( ; port <= 65535; port++ )); do
    if ! nc -z localhost "${port}" 2>/dev/null; then
      AVAILABLE_PORT="${port}"
      return 0
    fi
  done
  die "Could not find a free port starting from $1."
}

# ── Shared: ensure Docker daemon is running ───────────────────────────────────
ensure_docker_running() {
  if docker info &>/dev/null; then
    log "Docker is already running."
    return 0
  fi

  log "Docker is not running — starting it now…"
  case "$(uname -s)" in
    Darwin)
      open -a Docker
      ;;
    Linux)
      sudo systemctl start docker 2>/dev/null \
        || sudo service docker start 2>/dev/null \
        || die "Could not start Docker. Start it manually and retry."
      ;;
  esac

  log "Waiting for Docker to become ready…"
  local attempts=0
  while ! docker info &>/dev/null; do
    attempts=$(( attempts + 1 ))
    if [[ "${attempts}" -ge 30 ]]; then
      die "Docker did not become ready within 60 seconds. Start Docker manually and retry."
    fi
    sleep 2
  done
  log "Docker is ready."
}

# ── Shared: download and extract a DSS version installer ─────────────────────
# Sets the global FETCHED_INSTALLER_DIR to the unpacked installer path.
FETCHED_INSTALLER_DIR=""

fetch_installer() {
  local VERSION="$1"
  local ARCHIVE_NAME="dataiku-dss-${VERSION}-${PLATFORM}.tar.gz"
  local UNPACKED_DIR="dataiku-dss-${VERSION}-${PLATFORM}"
  local ARCHIVE_PATH="${DSS_VERSIONS_DIR}/${ARCHIVE_NAME}"
  local UNPACKED_PATH="${DSS_VERSIONS_DIR}/${UNPACKED_DIR}"

  mkdir -p "${DSS_VERSIONS_DIR}"

  if [[ -f "${UNPACKED_PATH}/installer.sh" ]]; then
    log "Version ${VERSION} already unpacked at ${UNPACKED_PATH}."
  else
    if [[ ! -f "${ARCHIVE_PATH}" ]]; then
      log "Downloading ${ARCHIVE_NAME}…"
      curl -fL --progress-bar "${BASE_URL}/${VERSION}/${ARCHIVE_NAME}" -o "${ARCHIVE_PATH}" \
        || { rm -f "${ARCHIVE_PATH}"; die "Download failed for version ${VERSION}. Check the version number and that it exists on downloads.dataiku.com."; }
      log "Download complete → ${ARCHIVE_PATH}"
    else
      log "Archive already exists, skipping download: ${ARCHIVE_PATH}"
    fi

    [[ -d "${UNPACKED_PATH}" ]] && rm -rf "${UNPACKED_PATH}"
    mkdir -p "${UNPACKED_PATH}"

    log "Extracting archive into ${UNPACKED_PATH}…"
    tar -xzf "${ARCHIVE_PATH}" -C "${UNPACKED_PATH}" \
      || { rm -rf "${UNPACKED_PATH}"; die "Extraction failed."; }

    # Collapse the inner sub-directory so installer.sh is directly inside UNPACKED_PATH.
    local SUBDIRS=( "${UNPACKED_PATH}"/dataiku-dss-*/ )
    if [[ ${#SUBDIRS[@]} -eq 1 && -d "${SUBDIRS[0]}" ]]; then
      local INNER="${SUBDIRS[0]%/}"
      local TEMP_DIR="${DSS_VERSIONS_DIR}/.tmp_${UNPACKED_DIR}"
      mv "${INNER}" "${TEMP_DIR}"
      rm -rf "${UNPACKED_PATH}"
      mv "${TEMP_DIR}" "${UNPACKED_PATH}"
    fi

    [[ -f "${UNPACKED_PATH}/installer.sh" ]] \
      || { rm -rf "${UNPACKED_PATH}"; die "installer.sh not found after extraction — archive layout may have changed."; }

    log "Extraction complete → ${UNPACKED_PATH}"
  fi

  xattr -rd com.apple.quarantine "${UNPACKED_PATH}" 2>/dev/null || true

  FETCHED_INSTALLER_DIR="${UNPACKED_PATH}"
}

# ── upgrade ───────────────────────────────────────────────────────────────────
upgrade_node() {
  local NODE_DIR="$1"
  local LATEST_VERSION="$2"
  local INSTALLER="$3"
  local NODE_NAME
  NODE_NAME="$(basename "${NODE_DIR}")"

  log "━━━ Node: ${NODE_NAME} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ ! -d "${NODE_DIR}" ]]; then
    log "[${NODE_NAME}] ⚠️  Directory not found — skipping."
    return 0
  fi

  local VERSION_FILE="${NODE_DIR}/dss-version.json"
  local CURRENT_VERSION="unknown"
  if [[ -f "${VERSION_FILE}" ]]; then
    CURRENT_VERSION=$(grep -oE '"product_version"\s*:\s*"[^"]+"' "${VERSION_FILE}" \
                      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
  fi

  if [[ "${CURRENT_VERSION}" == "${LATEST_VERSION}" ]]; then
    log "[${NODE_NAME}] Already at ${LATEST_VERSION} — skipping upgrade."
  else
    log "[${NODE_NAME}] Current version: ${CURRENT_VERSION} → upgrading to ${LATEST_VERSION}"

    local DSS_CTL="${NODE_DIR}/bin/dss"
    if [[ -x "${DSS_CTL}" ]]; then
      log "[${NODE_NAME}] Stopping…"
      "${DSS_CTL}" stop || log "[${NODE_NAME}] Was not running — continuing."
    else
      log "[${NODE_NAME}] Control script not found, skipping stop."
    fi

    log "[${NODE_NAME}] Running upgrade installer…"
    echo "Y" | "${INSTALLER}" -d "${NODE_DIR}" -u \
      || { log "❌ [${NODE_NAME}] Upgrade installer failed."; return 1; }
    log "[${NODE_NAME}] ✅ Upgrade complete."

    DSS_CTL="${NODE_DIR}/bin/dss"
    if [[ -x "${DSS_CTL}" ]]; then
      log "[${NODE_NAME}] Starting…"
      "${DSS_CTL}" start || log "[${NODE_NAME}] ⚠️  Start may have failed. Check manually."
    else
      log "[${NODE_NAME}] ⚠️  Control script not found after upgrade. Check manually."
    fi
  fi

  local DSSADMIN="${NODE_DIR}/bin/dssadmin"
  if [[ -x "${DSSADMIN}" ]]; then
    log "[${NODE_NAME}] Rebuilding Docker base image (linux/amd64, no cache)…"
    "${DSSADMIN}" build-base-image \
      --type container-exec \
      --without-r \
      --docker-build-opt=--no-cache \
      --docker-build-opt='--platform' \
      --docker-build-opt='linux/amd64' \
      || { log "❌ [${NODE_NAME}] Docker image build failed."; return 1; }
    log "[${NODE_NAME}] ✅ Docker base image rebuilt."
  else
    log "[${NODE_NAME}] dssadmin not found — skipping Docker image rebuild."
  fi
}

cmd_upgrade() {
  ensure_docker_running

  log "Fetching version list from downloads.dataiku.com…"
  local LATEST_VERSION
  LATEST_VERSION=$(
    curl -fsSL "${BASE_URL}/" \
    | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -V \
    | tail -1
  )
  [[ -z "${LATEST_VERSION}" ]] && die "Could not determine the latest DSS version."
  log "Latest DSS version found: ${LATEST_VERSION}"

  fetch_installer "${LATEST_VERSION}"
  local INSTALLER="${FETCHED_INSTALLER_DIR}/installer.sh"
  [[ -x "${INSTALLER}" ]] || chmod +x "${INSTALLER}"

  local OVERALL_SUCCESS=true
  for NODE_DIR in "${DSS_NODES[@]}"; do
    upgrade_node "${NODE_DIR}" "${LATEST_VERSION}" "${INSTALLER}" || OVERALL_SUCCESS=false
  done

  ${OVERALL_SUCCESS} || die "One or more nodes failed. Review the log above."

  log "Cleaning up old DSS versions from ${DSS_VERSIONS_DIR}…"
  local UNPACKED_PATH="${FETCHED_INSTALLER_DIR}"
  local ARCHIVE_PATH="${DSS_VERSIONS_DIR}/dataiku-dss-${LATEST_VERSION}-${PLATFORM}.tar.gz"
  local REMOVED=0

  for OLD_DIR in "${DSS_VERSIONS_DIR}"/dataiku-dss-*-"${PLATFORM}"; do
    [[ -d "${OLD_DIR}" ]] || continue
    [[ "${OLD_DIR}" == "${UNPACKED_PATH}" ]] && continue
    log "  Removing directory: $(basename "${OLD_DIR}")"
    rm -rf "${OLD_DIR}"
    (( REMOVED++ )) || true
  done
  for OLD_TGZ in "${DSS_VERSIONS_DIR}"/dataiku-dss-*-"${PLATFORM}".tar.gz; do
    [[ -f "${OLD_TGZ}" ]] || continue
    [[ "${OLD_TGZ}" == "${ARCHIVE_PATH}" ]] && continue
    log "  Removing archive: $(basename "${OLD_TGZ}")"
    rm -f "${OLD_TGZ}"
    (( REMOVED++ )) || true
  done
  if [[ -f "${ARCHIVE_PATH}" ]]; then
    log "  Removing current archive: $(basename "${ARCHIVE_PATH}")"
    rm -f "${ARCHIVE_PATH}"
    (( REMOVED++ )) || true
  fi
  log "Cleanup complete — removed ${REMOVED} item(s)."

  log "✅ DSS successfully upgraded to ${LATEST_VERSION}!"
}

# ── install ───────────────────────────────────────────────────────────────────
cmd_install() {
  local VERSION="${1:-}"
  [[ -z "${VERSION}" ]] && die "Version required. Usage: bash dss.sh install <version>  (e.g. 14.5.1)"

  local INSTALL_DIR="${DSS_BASE_DIR}/dss_${VERSION}"

  if [[ -d "${INSTALL_DIR}" ]]; then
    log "⚠️  ${INSTALL_DIR} already exists. Remove it first or choose a different version."
    exit 1
  fi

  find_available_port "${DSS_INSTALL_PORT}"
  local PORT="${AVAILABLE_PORT}"
  if [[ "${PORT}" != "${DSS_INSTALL_PORT}" ]]; then
    log "⚠️  Port ${DSS_INSTALL_PORT} is already in use — using port ${PORT} instead."
  else
    log "Port ${PORT} is available."
  fi

  log "Installing DSS ${VERSION} → ${INSTALL_DIR} (port ${PORT})…"

  fetch_installer "${VERSION}"
  local INSTALLER="${FETCHED_INSTALLER_DIR}/installer.sh"
  [[ -x "${INSTALLER}" ]] || chmod +x "${INSTALLER}"

  mkdir -p "${INSTALL_DIR}"

  log "Running installer…"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    # This script runs under Rosetta (x86_64), but system Java is arm64-only.
    # Run the installer natively (arm64) so it can locate the arm64 JVM.
    # The installed DSS uses its own bundled JRE at runtime, so this is only
    # needed for the install step itself.
    # Prefer Java 11, then 8, then whatever is available — older DSS versions
    # reject Java 17+ even though it mostly works, so we pick the best match.
    local JAVA_HOME_NATIVE
    JAVA_HOME_NATIVE="$( /usr/libexec/java_home -v 11 2>/dev/null \
      || /usr/libexec/java_home -v 1.8 2>/dev/null \
      || /usr/libexec/java_home 2>/dev/null )" || true
    if [[ -n "${JAVA_HOME_NATIVE}" ]]; then
      log "Running installer as arm64 with JAVA_HOME=${JAVA_HOME_NATIVE}"
    fi
    JAVA_HOME="${JAVA_HOME_NATIVE}" \
      /usr/bin/arch -arm64 /bin/bash "${INSTALLER}" \
        -d "${INSTALL_DIR}" -p "${PORT}" \
      || { rm -rf "${INSTALL_DIR}"; die "Installation failed."; }
  else
    "${INSTALLER}" -d "${INSTALL_DIR}" -p "${PORT}" \
      || { rm -rf "${INSTALL_DIR}"; die "Installation failed."; }
  fi

  # Some older installers exit 0 even when they fail (e.g. unsupported OS / missing Java).
  # Verify the install actually completed by checking for the control script.
  if [[ ! -x "${INSTALL_DIR}/bin/dss" ]]; then
    rm -rf "${INSTALL_DIR}"
    die "Installer exited without error but DSS was not fully installed. The OS or Java version may not be supported by DSS ${VERSION}."
  fi

  log "Starting DSS ${VERSION}…"
  "${INSTALL_DIR}/bin/dss" start \
    || log "⚠️  Start may have failed. Check manually."

  log "✅ DSS ${VERSION} installed and running at ${INSTALL_DIR} on port ${PORT}"
  log "   Stop:   ${INSTALL_DIR}/bin/dss stop"
  log "   Remove: bash dss.sh remove ${VERSION}"
}

# ── remove ────────────────────────────────────────────────────────────────────
cmd_remove() {
  local VERSION="${1:-}"
  [[ -z "${VERSION}" ]] && die "Version required. Usage: bash dss.sh remove <version>  (e.g. 14.5.1)"

  local INSTALL_DIR="${DSS_BASE_DIR}/dss_${VERSION}"
  [[ -d "${INSTALL_DIR}" ]] || die "No installation found at ${INSTALL_DIR}"

  local DSS_CTL="${INSTALL_DIR}/bin/dss"
  if [[ -x "${DSS_CTL}" ]]; then
    log "Stopping DSS ${VERSION}…"
    "${DSS_CTL}" stop 2>/dev/null || log "Was not running."
  fi

  log "Removing ${INSTALL_DIR}…"
  rm -rf "${INSTALL_DIR}"
  log "✅ DSS ${VERSION} removed."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: bash dss.sh <command> [args]"
  echo ""
  echo "Commands:"
  echo "  upgrade              Upgrade configured nodes to the latest DSS release"
  echo "  install <version>    Install DSS <version> to ${DSS_BASE_DIR}/dss_<version>"
  echo "  remove  <version>    Stop and delete the installation at ${DSS_BASE_DIR}/dss_<version>"
  echo ""
  echo "Env var overrides (all optional):"
  echo "  DSS_BASE_DIR         Base directory for installs       (default: ~/dss)"
  echo "  DSS_VERSIONS_DIR     Directory for downloaded installers (default: ~/dss/installers)"
  echo "  DSS_INSTALL_PORT     TCP port for fresh installs        (default: 10000)"
  echo "  DSS_NODES_LIST       Colon-separated node paths for upgrade"
  exit 1
}

case "${1:-}" in
  upgrade) cmd_upgrade ;;
  install) cmd_install "${2:-}" ;;
  remove)  cmd_remove  "${2:-}" ;;
  *)       usage ;;
esac

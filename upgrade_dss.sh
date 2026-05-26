#!/bin/bash
#
# upgrade_dss.sh — Upgrade all local DSS nodes to the latest public release.
#
# Usage: bash upgrade_dss.sh
#
# Edit the CONFIGURATION section below, then run. No other changes needed.

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

# Where extracted DSS releases are stored (script downloads here and cleans up old versions).
# Override: DSS_VERSIONS_DIR=~/my/path bash upgrade_dss.sh
DSS_VERSIONS_DIR="${DSS_VERSIONS_DIR:-${HOME}/dss/dss_13/dss_versions}"

# Nodes to upgrade, in dependency order (design first, then deployer, then automation).
# Paths that don't exist are skipped automatically — safe to leave extras in the list.
# Override via a colon-separated env var:
#   DSS_NODES_LIST="${HOME}/node1:${HOME}/node2" bash upgrade_dss.sh
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

# Detect platform: "osx" on macOS, "linux" on Linux.
case "$(uname -s)" in
  Darwin) PLATFORM="osx" ;;
  Linux)  PLATFORM="linux" ;;
  *)      echo "❌ Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "❌ ERROR: $*" >&2; exit 1; }

# ── Step 1: Discover the latest version ───────────────────────────────────────
log "Fetching version list from downloads.dataiku.com…"
LATEST_VERSION=$(
  curl -fsSL "${BASE_URL}/" \
  | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
  | sort -V \
  | tail -1
)

[[ -z "${LATEST_VERSION}" ]] && die "Could not determine the latest DSS version."
log "Latest DSS version found: ${LATEST_VERSION}"

ARCHIVE_NAME="dataiku-dss-${LATEST_VERSION}-${PLATFORM}.tar.gz"
UNPACKED_DIR="dataiku-dss-${LATEST_VERSION}-${PLATFORM}"
DOWNLOAD_URL="${BASE_URL}/${LATEST_VERSION}/${ARCHIVE_NAME}"

# ── Step 2: Check if already downloaded / installed ───────────────────────────
mkdir -p "${DSS_VERSIONS_DIR}"

ARCHIVE_PATH="${DSS_VERSIONS_DIR}/${ARCHIVE_NAME}"
UNPACKED_PATH="${DSS_VERSIONS_DIR}/${UNPACKED_DIR}"

if [[ -f "${UNPACKED_PATH}/installer.sh" ]]; then
  log "Version ${LATEST_VERSION} is already unpacked at ${UNPACKED_PATH}."
  log "Skipping download and extraction."
else
  # ── Step 3: Download ─────────────────────────────────────────────────────────
  if [[ -f "${ARCHIVE_PATH}" ]]; then
    log "Archive already exists, skipping download: ${ARCHIVE_PATH}"
  else
    log "Downloading ${ARCHIVE_NAME}…"
    curl -L --progress-bar "${DOWNLOAD_URL}" -o "${ARCHIVE_PATH}" \
      || die "Download failed. URL: ${DOWNLOAD_URL}"
    log "Download complete → ${ARCHIVE_PATH}"
  fi

  # ── Step 4: Extract ──────────────────────────────────────────────────────────
  # Clean up any partial extraction before starting.
  [[ -d "${UNPACKED_PATH}" ]] && rm -rf "${UNPACKED_PATH}"
  mkdir -p "${UNPACKED_PATH}"

  log "Extracting archive into ${UNPACKED_PATH}…"
  tar -xzf "${ARCHIVE_PATH}" -C "${UNPACKED_PATH}" \
    || { rm -rf "${UNPACKED_PATH}"; die "Extraction failed."; }

  # The archive contains a single top-level sub-directory (e.g.
  # dataiku-dss-14.5.1/ or dataiku-dss-14.5.1-osx/).  Collapse it so that
  # installer.sh ends up directly inside UNPACKED_PATH.
  SUBDIRS=( "${UNPACKED_PATH}"/dataiku-dss-*/ )
  if [[ ${#SUBDIRS[@]} -eq 1 && -d "${SUBDIRS[0]}" ]]; then
    INNER="${SUBDIRS[0]%/}"
    log "Collapsing inner directory $(basename "${INNER}") into ${UNPACKED_PATH}…"
    TEMP_DIR="${DSS_VERSIONS_DIR}/.tmp_${UNPACKED_DIR}"
    mv "${INNER}" "${TEMP_DIR}"
    rm -rf "${UNPACKED_PATH}"
    mv "${TEMP_DIR}" "${UNPACKED_PATH}"
  fi

  [[ -f "${UNPACKED_PATH}/installer.sh" ]] \
    || { rm -rf "${UNPACKED_PATH}"; die "installer.sh not found after extraction — archive layout may have changed."; }

  log "Extraction complete → ${UNPACKED_PATH}"
fi

# ── Step 5: Remove macOS quarantine attributes ────────────────────────────────
log "Removing quarantine attributes…"
xattr -rd com.apple.quarantine "${UNPACKED_PATH}" 2>/dev/null || true
log "Quarantine attributes cleared."

# ── Steps 6-9: Per-node: Stop → Upgrade → Start → Rebuild Docker ─────────────
INSTALLER="${UNPACKED_PATH}/installer.sh"
[[ -x "${INSTALLER}" ]] || chmod +x "${INSTALLER}"

upgrade_node() {
  local NODE_DIR="$1"
  local NODE_NAME
  NODE_NAME="$(basename "${NODE_DIR}")"

  log "━━━ Node: ${NODE_NAME} ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ ! -d "${NODE_DIR}" ]]; then
    log "[${NODE_NAME}] ⚠️  Directory not found — skipping."
    return 0
  fi

  # ── Check current version ──────────────────────────────────────────────────
  # DSS writes the installed version into dss-version.json.
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

    # Stop
    local DSS_CTL="${NODE_DIR}/bin/dss"
    if [[ -x "${DSS_CTL}" ]]; then
      log "[${NODE_NAME}] Stopping…"
      "${DSS_CTL}" stop || log "[${NODE_NAME}] Was not running — continuing."
    else
      log "[${NODE_NAME}] Control script not found, skipping stop."
    fi

    # Upgrade
    log "[${NODE_NAME}] Running upgrade installer…"
    echo "Y" | "${INSTALLER}" -d "${NODE_DIR}" -u \
      || { log "❌ [${NODE_NAME}] Upgrade installer failed."; return 1; }
    log "[${NODE_NAME}] ✅ Upgrade complete."

    # Start
    DSS_CTL="${NODE_DIR}/bin/dss"   # refresh — installer may have replaced it
    if [[ -x "${DSS_CTL}" ]]; then
      log "[${NODE_NAME}] Starting…"
      "${DSS_CTL}" start || log "[${NODE_NAME}] ⚠️  Start may have failed. Check manually."
    else
      log "[${NODE_NAME}] ⚠️  Control script not found after upgrade. Check manually."
    fi
  fi

  # ── Rebuild Docker base image ──────────────────────────────────────────────
  # Run on every node that has dssadmin, whether or not an upgrade occurred,
  # because the user may want images in sync across all nodes.
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

OVERALL_SUCCESS=true
for NODE_DIR in "${DSS_NODES[@]}"; do
  upgrade_node "${NODE_DIR}" || OVERALL_SUCCESS=false
done

${OVERALL_SUCCESS} || die "One or more nodes failed. Review the log above."

# ── Step 10: Remove old DSS version files ────────────────────────────────────
log "Cleaning up old DSS versions from ${DSS_VERSIONS_DIR}…"
REMOVED=0
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
# Also remove the current version's archive now that it's been extracted.
if [[ -f "${ARCHIVE_PATH}" ]]; then
  log "  Removing current archive: $(basename "${ARCHIVE_PATH}")"
  rm -f "${ARCHIVE_PATH}"
  (( REMOVED++ )) || true
fi
log "Cleanup complete — removed ${REMOVED} item(s)."

log "✅ DSS successfully upgraded to ${LATEST_VERSION}!"

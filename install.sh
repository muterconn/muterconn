#!/bin/bash
################################################################################
# muterconn Install / Update Script
#
# Supports first-time install and idempotent binary updates.
#
# Usage:
#   sudo ./scripts/install.sh
#
# What it does:
#   1. Verifies running as root
#   2. apt update + install adb
#   3. Write /etc/security/limits.d/99-muterconn.conf
#   4. Scaffold /opt/muterconn/muterconn/{bin,data,log}
#   5. Download latest release binary from github.com/muterconn/muterconn
#   6. Verify SHA-256 of downloaded binary
#   7. Install / replace binary (service stopped first if running)
#   8. Install systemd service
#   9. Install rsyslog ignore rule
#  10. Install logrotate config
#  11. Enable + (re)start service
################################################################################

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
GITHUB_REPO="muterconn/muterconn"
INSTALL_DIR="/opt/muterconn/muterconn"
BIN_DIR="${INSTALL_DIR}/bin"
BINARY="${BIN_DIR}/muterconn"
SERVICE_NAME="muterconn"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ── 1. Root check ─────────────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo ./scripts/install.sh)" >&2
    exit 1
fi

echo "==> [1/10] Verified running as root"

# ── 2. System packages ────────────────────────────────────────────────────────
echo "==> [2/10] apt update + install adb"
apt-get update -qq
apt-get install -y -qq adb curl

# ── 3. Resource limits ────────────────────────────────────────────────────────
echo "==> [3/10] Writing /etc/security/limits.d/99-muterconn.conf"
cat > /etc/security/limits.d/99-muterconn.conf << 'EOF'
# muterconn resource limits
# Allows muterconn to manage large numbers of USB device file descriptors.
*    soft    nofile    unlimited
*    hard    nofile    unlimited
*    soft    nproc     65535
*    hard    nproc     65535
EOF

# ── 4. Directory scaffold ─────────────────────────────────────────────────────
echo "==> [4/10] Scaffolding ${INSTALL_DIR}"
mkdir -p "${BIN_DIR}"
mkdir -p "${INSTALL_DIR}/data"
mkdir -p "${INSTALL_DIR}/log"
chmod 700 "${INSTALL_DIR}/data"   # license file + SQLite DB — keep private
chmod 755 "${INSTALL_DIR}/log"

# ── 5. Fetch latest release metadata from GitHub ─────────────────────────────
echo "==> [5/10] Fetching latest release info from github.com/${GITHUB_REPO}"
RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")
TAG=$(echo "${RELEASE_JSON}" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [[ -z "${TAG}" ]]; then
    echo "ERROR: Could not determine latest release tag from GitHub API" >&2
    exit 1
fi

echo "    Latest tag: ${TAG}"

# Find the binary asset URL (asset named exactly 'muterconn')
ASSET_URL=$(echo "${RELEASE_JSON}" | grep '"browser_download_url"' | grep '/muterconn"' | head -1 | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')

if [[ -z "${ASSET_URL}" ]]; then
    echo "ERROR: Could not find 'muterconn' asset in release ${TAG}" >&2
    echo "       Available assets:" >&2
    echo "${RELEASE_JSON}" | grep '"name"' | grep -v '"tag_name"' >&2
    exit 1
fi

echo "    Asset URL: ${ASSET_URL}"

# ── 6. Download + SHA-256 verify ──────────────────────────────────────────────
echo "==> [6/10] Downloading binary"
TMP_BINARY=$(mktemp /tmp/muterconn.XXXXXX)
TMP_SHA=$(mktemp /tmp/muterconn-sha.XXXXXX)
# Ensure temp files are cleaned up on any exit
trap 'rm -f "${TMP_BINARY}" "${TMP_SHA}"' EXIT

curl -fsSL --output "${TMP_BINARY}" "${ASSET_URL}"

# SHA-256 is published as the release body text in the format:
#   SHA-256: `<hex>` or SHA-256: <hex>
# Extract it from the release JSON field "body"
EXPECTED_SHA=$(echo "${RELEASE_JSON}" | grep -o 'SHA-256[^`"]*`[a-f0-9]\{64\}`\|SHA-256: *[a-f0-9]\{64\}' | grep -o '[a-f0-9]\{64\}' | head -1)

if [[ -n "${EXPECTED_SHA}" ]]; then
    echo "    Verifying SHA-256..."
    ACTUAL_SHA=$(sha256sum "${TMP_BINARY}" | awk '{print $1}')
    if [[ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]]; then
        echo "ERROR: SHA-256 mismatch!" >&2
        echo "  Expected: ${EXPECTED_SHA}" >&2
        echo "  Actual:   ${ACTUAL_SHA}" >&2
        exit 1
    fi
    echo "    SHA-256 OK: ${ACTUAL_SHA}"
else
    echo "    WARNING: No SHA-256 found in release body — skipping integrity check"
fi

# ── 7. Stop service (if running), install binary ──────────────────────────────
echo "==> [7/10] Installing binary to ${BINARY}"
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo "    Stopping ${SERVICE_NAME} service..."
    systemctl stop "${SERVICE_NAME}"
fi

chmod 755 "${TMP_BINARY}"
mv "${TMP_BINARY}" "${BINARY}"
# Trap no longer needs to remove TMP_BINARY since it was moved
trap 'rm -f "${TMP_SHA}"' EXIT

echo "    Installed: ${BINARY}"
echo "    Version tag: ${TAG}"

# ── 8. systemd service ────────────────────────────────────────────────────────
echo "==> [8/10] Installing systemd service"
cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Muterconn Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
SyslogIdentifier=muterconn
StandardOutput=journal
StandardError=journal

User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BINARY}

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

# ── 9. rsyslog ignore rule ────────────────────────────────────────────────────
echo "==> [9/10] Installing rsyslog ignore rule"
cat > /etc/rsyslog.d/00-muterconn-ignore.conf << 'EOF'
# If the program name is 'muterconn', stop processing here.
# This prevents it from reaching the default syslog rules below.
if $programname == 'muterconn' then stop
EOF

if systemctl is-active --quiet rsyslog 2>/dev/null; then
    systemctl restart rsyslog
fi

# ── 10. logrotate config ──────────────────────────────────────────────────────
echo "==> [10/10] Installing logrotate config"
cat > /etc/logrotate.d/muterconn << EOF
${INSTALL_DIR}/log/log.txt {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    # copytruncate: Go keeps the file descriptor open; we copy then truncate
    # rather than moving, so the process keeps writing to the same fd.
    copytruncate
}
EOF

# ── Start / restart service ───────────────────────────────────────────────────
echo "==> Starting ${SERVICE_NAME}..."
systemctl start "${SERVICE_NAME}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  muterconn ${TAG} installed successfully"
echo ""
echo "  Binary:   ${BINARY}"
echo "  Data:     ${INSTALL_DIR}/data"
echo "  Logs:     ${INSTALL_DIR}/log/log.txt"
echo ""
echo "  journalctl -u muterconn -f    — live journal"
echo "  tail -f ${INSTALL_DIR}/log/log.txt   — app log file"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

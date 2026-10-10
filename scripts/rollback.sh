#!/bin/bash
# Restores a previously installed AI Usage Monitor from ~/.ai-usage/backups.
# The copy being replaced is kept as a backup too, so a rollback can itself be undone.
set -euo pipefail

APP_NAME="AI Usage Monitor"
INSTALL_PATH="/Applications/${APP_NAME}.app"
BACKUP_DIR="${HOME}/.ai-usage/backups"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<EOF
Usage: scripts/rollback.sh [--list | <backup.app>]

  With no argument, restores the newest backup.
  --list         Shows the available backups, newest first.
  <backup.app>   Restores that specific backup.
EOF
}

list_backups() {
    find "${BACKUP_DIR}" -maxdepth 1 -name "${APP_NAME} *.app" -print0 2>/dev/null \
        | xargs -0 ls -dt 2>/dev/null || true
}

target=""
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --list) list_backups; exit 0 ;;
    "") target="$(list_backups | head -n 1)" ;;
    *) target="$1" ;;
esac

if [[ -z "${target}" || ! -x "${target}/Contents/MacOS/${APP_NAME}" ]]; then
    echo "error: no usable backup found${target:+ at ${target}}." >&2
    echo "       Backups live in ${BACKUP_DIR}; see scripts/rollback.sh --list." >&2
    exit 1
fi

source "${REPO_ROOT}/scripts/app-control.sh"

# Copy the chosen backup out first: the step below adds a new backup to the same folder.
staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT
ditto "${target}" "${staging}/${APP_NAME}.app"

quit_app

if [[ -d "${INSTALL_PATH}" ]]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    echo "==> Keeping the current app as ${BACKUP_DIR}/${APP_NAME} ${stamp}.app"
    mkdir -p "${BACKUP_DIR}"
    chmod 700 "${BACKUP_DIR}"
    ditto "${INSTALL_PATH}" "${BACKUP_DIR}/${APP_NAME} ${stamp}.app"
fi

echo "==> Restoring ${target}"
replace_installed_app "${staging}/${APP_NAME}.app"
open "${INSTALL_PATH}"
echo "Restored. Usage history and settings in ~/.ai-usage are shared by both versions and were not changed."

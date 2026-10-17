#!/bin/bash
# Restores a previously installed AI Usage Monitor from ~/.ai-usage/backups.
#
# Backups work like a stack: each rollback restores the newest backup saved by install.sh and
# removes it from the list, so running rollback again goes one install further back. The build
# being replaced is kept as "<name> replaced <time>.app", which you can restore explicitly to
# roll forward again.
set -euo pipefail

APP_NAME="AI Usage Monitor"
INSTALL_PATH="${AI_USAGE_MONITOR_INSTALL_PATH:-/Applications/${APP_NAME}.app}"
BACKUP_DIR="${AI_USAGE_MONITOR_BACKUP_DIR:-${HOME}/.ai-usage/backups}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

source "${REPO_ROOT}/scripts/app-control.sh"

usage() {
    cat <<USAGE
Usage: scripts/rollback.sh [--list | <backup.app>]

  With no argument, restores the newest backup saved by install.sh.
  --list         Shows the available backups, newest first.
  <backup.app>   Restores that specific backup, for example a "replaced" one to roll forward.
USAGE
}

target=""
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --list)
        echo "Saved by install.sh (restored by default, newest first):"
        install_backups | sed 's/^/  /'
        echo "Replaced by a rollback (restore one explicitly to roll forward):"
        replaced_backups | sed 's/^/  /'
        exit 0 ;;
    "") target="$(install_backups | head -n 1)" ;;
    *) target="$1" ;;
esac

if [[ -z "${target}" || ! -x "${target}/Contents/MacOS/${APP_NAME}" ]]; then
    echo "error: no usable backup found${target:+ at ${target}}." >&2
    echo "       Backups live in ${BACKUP_DIR}; see scripts/rollback.sh --list." >&2
    exit 1
fi

# Copy the chosen backup out first: the step below adds a new backup to the same folder.
staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT
ditto "${target}" "${staging}/${APP_NAME}.app"

quit_app
ensure_backup_dir

if [[ -d "${INSTALL_PATH}" ]]; then
    replaced_path="$(new_backup_path "replaced ")"
    echo "==> Keeping the current app as ${replaced_path}"
    ditto "${INSTALL_PATH}" "${replaced_path}"
fi

echo "==> Restoring ${target}"
replace_installed_app "${staging}/${APP_NAME}.app"

# The restored build is now the installed one, so it leaves the backup list.
if [[ "$(cd "$(dirname "${target}")" && pwd)" == "$(cd "${BACKUP_DIR}" && pwd)" ]]; then
    rm -rf "${target}"
fi

launch_app
echo "Restored. Usage history and settings in ~/.ai-usage are shared by both versions and were not changed."

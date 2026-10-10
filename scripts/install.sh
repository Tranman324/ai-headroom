#!/bin/bash
# Builds AI Usage Monitor, checks that the new build can read usage, backs up the installed
# copy, then installs and relaunches. Undo with scripts/rollback.sh.
set -euo pipefail

APP_NAME="AI Usage Monitor"
INSTALL_PATH="${AI_USAGE_MONITOR_INSTALL_PATH:-/Applications/${APP_NAME}.app}"
BACKUP_DIR="${AI_USAGE_MONITOR_BACKUP_DIR:-${HOME}/.ai-usage/backups}"
KEEP_BACKUPS=5
KEEP_REPLACED=3
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${REPO_ROOT}/build/DerivedData"
BUILT_APP="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
XCODEBUILD_ARGS=(-project "${REPO_ROOT}/AI Usage Monitor.xcodeproj" -scheme "${APP_NAME}" -destination platform=macOS -derivedDataPath "${DERIVED_DATA}" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO)

run_tests=1
require_healthy=1

usage() {
    cat <<EOF
Usage: scripts/install.sh [--skip-tests] [--force]

  --skip-tests  Do not run the unit tests before building.
  --force       Install even if the new build cannot read usage from both providers
                (for example when only one provider is installed on this Mac).
EOF
}

for argument in "$@"; do
    case "${argument}" in
        --skip-tests) run_tests=0 ;;
        --force) require_healthy=0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
done

source "${REPO_ROOT}/scripts/app-control.sh"

if [[ ${run_tests} -eq 1 ]]; then
    echo "==> Running unit tests"
    xcodebuild test "${XCODEBUILD_ARGS[@]}" -only-testing:"${APP_NAME}Tests" -quiet
fi

echo "==> Building Release"
xcodebuild build "${XCODEBUILD_ARGS[@]}" -configuration Release -quiet
if [[ ! -x "${BUILT_APP}/Contents/MacOS/${APP_NAME}" ]]; then
    echo "error: build did not produce ${BUILT_APP}" >&2
    exit 1
fi

echo "==> Checking the new build against your real Claude and Codex setup"
if ! "${BUILT_APP}/Contents/MacOS/${APP_NAME}" --diagnose; then
    if [[ ${require_healthy} -eq 1 ]]; then
        echo "error: the new build could not read usage; the installed app was not changed." >&2
        echo "       Fix the problem above, or rerun with --force to install anyway." >&2
        exit 1
    fi
    echo "warning: installing anyway because of --force" >&2
fi

ensure_backup_dir
quit_app

if [[ -d "${INSTALL_PATH}" ]]; then
    backup_path="$(new_backup_path "")"
    echo "==> Backing up the installed app to ${backup_path}"
    ditto "${INSTALL_PATH}" "${backup_path}"
fi

echo "==> Installing to ${INSTALL_PATH}"
replace_installed_app "${BUILT_APP}"

# Keep only the newest backups of each kind.
install_backups | tail -n +$((KEEP_BACKUPS + 1)) | while IFS= read -r old_backup; do rm -rf "${old_backup}"; done
replaced_backups | tail -n +$((KEEP_REPLACED + 1)) | while IFS= read -r old_backup; do rm -rf "${old_backup}"; done

launch_app

echo "==> Checking the installed app"
"${INSTALL_PATH}/Contents/MacOS/${APP_NAME}" --diagnose || true
echo
echo "Installed. To undo: scripts/rollback.sh"

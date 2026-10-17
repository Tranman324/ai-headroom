#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TEST_BIN="${TEST_ROOT}/bin"
INSTALL_PATH="${TEST_ROOT}/Applications/AI Usage Monitor.app"
BACKUP_DIR="${TEST_ROOT}/backups"
DERIVED_DATA="${TEST_ROOT}/DerivedData"

cleanup() {
    rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

mkdir -p "${TEST_BIN}" "$(dirname "${INSTALL_PATH}")" "${BACKUP_DIR}"
export HOME="${TEST_ROOT}/home"
export AI_USAGE_MONITOR_INSTALL_PATH="${INSTALL_PATH}"
export AI_USAGE_MONITOR_BACKUP_DIR="${BACKUP_DIR}"
export AI_USAGE_MONITOR_DERIVED_DATA_PATH="${DERIVED_DATA}"
export AI_USAGE_MONITOR_SKIP_LAUNCH=1
export PATH="${TEST_BIN}:${PATH}"

cat > "${TEST_BIN}/xcodebuild" <<'XCODEBUILD'
#!/bin/bash
set -euo pipefail
derived_data=""
while (($#)); do
    if [[ "$1" == "-derivedDataPath" ]]; then
        derived_data="$2"
        shift 2
    else
        shift
    fi
done
[[ -n "${derived_data}" ]]
app="${derived_data}/Build/Products/Release/AI Usage Monitor.app"
mkdir -p "${app}/Contents/MacOS"
printf '%s\n' "${FAKE_BUILD_ID:-new-build}" > "${app}/Contents/TEST_BUILD_ID"
cat > "${app}/Contents/MacOS/AI Usage Monitor" <<'APP'
#!/bin/bash
if [[ "${1:-}" == "--diagnose" ]]; then
    exit "${FAKE_DIAG_EXIT:-0}"
fi
APP
chmod +x "${app}/Contents/MacOS/AI Usage Monitor"
XCODEBUILD
chmod +x "${TEST_BIN}/xcodebuild"

cat > "${TEST_BIN}/mv" <<'MV'
#!/bin/bash
if [[ "${FAIL_APP_INSTALL_MOVE:-0}" == "1" \
      && "${1:-}" == *".incoming.app" \
      && "${2:-}" == "${AI_USAGE_MONITOR_INSTALL_PATH}" ]]; then
    exit 1
fi
exec /bin/mv "$@"
MV
chmod +x "${TEST_BIN}/mv"

create_bundle() {
    local bundle="$1"
    local build_id="$2"
    mkdir -p "${bundle}/Contents/MacOS"
    printf '%s\n' "${build_id}" > "${bundle}/Contents/TEST_BUILD_ID"
    cat > "${bundle}/Contents/MacOS/AI Usage Monitor" <<'APP'
#!/bin/bash
if [[ "${1:-}" == "--diagnose" ]]; then
    exit "${FAKE_DIAG_EXIT:-0}"
fi
APP
    chmod +x "${bundle}/Contents/MacOS/AI Usage Monitor"
}

bundle_id() {
    cat "$1/Contents/TEST_BUILD_ID"
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

create_bundle "${INSTALL_PATH}" "original"

FAKE_BUILD_ID=installed FAKE_DIAG_EXIT=0 "${REPO_ROOT}/scripts/install.sh" --skip-tests > "${TEST_ROOT}/install.log" 2>&1 \
    || { cat "${TEST_ROOT}/install.log" >&2; fail "healthy install failed"; }
[[ "$(bundle_id "${INSTALL_PATH}")" == "installed" ]] || fail "install did not replace the app"
install_backups=("${BACKUP_DIR}"/AI\ Usage\ Monitor\ [0-9]*.app)
[[ ${#install_backups[@]} -eq 1 ]] || fail "install did not preserve exactly one backup"
[[ "$(bundle_id "${install_backups[0]}")" == "original" ]] || fail "install backup did not preserve the original app"
[[ "$(stat -f '%Lp' "${BACKUP_DIR}")" == "700" ]] || fail "backup directory permissions are not 0700"

"${REPO_ROOT}/scripts/rollback.sh" > "${TEST_ROOT}/rollback.log" 2>&1 \
    || { cat "${TEST_ROOT}/rollback.log" >&2; fail "rollback failed"; }
[[ "$(bundle_id "${INSTALL_PATH}")" == "original" ]] || fail "rollback did not restore the previous app"
replaced_backups=("${BACKUP_DIR}"/AI\ Usage\ Monitor\ replaced\ [0-9]*.app)
[[ ${#replaced_backups[@]} -eq 1 ]] || fail "rollback did not preserve the replaced app"
[[ "$(bundle_id "${replaced_backups[0]}")" == "installed" ]] || fail "rollback's replaced-app backup is incorrect"

"${REPO_ROOT}/scripts/rollback.sh" "${replaced_backups[0]}" > "${TEST_ROOT}/roll-forward.log" 2>&1 \
    || { cat "${TEST_ROOT}/roll-forward.log" >&2; fail "explicit roll-forward failed"; }
[[ "$(bundle_id "${INSTALL_PATH}")" == "installed" ]] || fail "explicit roll-forward did not restore the selected app"

if FAKE_BUILD_ID=unhealthy FAKE_DIAG_EXIT=7 "${REPO_ROOT}/scripts/install.sh" --skip-tests > "${TEST_ROOT}/unhealthy.log" 2>&1; then
    fail "install accepted an unhealthy build without --force"
fi
[[ "$(bundle_id "${INSTALL_PATH}")" == "installed" ]] || fail "unhealthy build changed the installed app"
[[ ! -e "${INSTALL_PATH%.app}.incoming.app" && ! -e "${INSTALL_PATH%.app}.outgoing.app" ]] \
    || fail "unhealthy build left a partial replacement"

if FAIL_APP_INSTALL_MOVE=1 FAKE_BUILD_ID=failed-swap FAKE_DIAG_EXIT=0 \
    "${REPO_ROOT}/scripts/install.sh" --skip-tests > "${TEST_ROOT}/failed-install.log" 2>&1; then
    fail "install reported success after the replacement move failed"
fi
[[ "$(bundle_id "${INSTALL_PATH}")" == "installed" ]] || fail "failed install did not restore the installed app"
[[ ! -e "${INSTALL_PATH%.app}.incoming.app" && ! -e "${INSTALL_PATH%.app}.outgoing.app" ]] \
    || fail "failed install left partial replacement bundles"

find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
create_bundle "${BACKUP_DIR}/AI Usage Monitor 20990101-000000.app" "rollback-target"
create_bundle "${INSTALL_PATH}" "rollback-current"
if FAIL_APP_INSTALL_MOVE=1 "${REPO_ROOT}/scripts/rollback.sh" > "${TEST_ROOT}/failed-rollback.log" 2>&1; then
    fail "rollback reported success after the replacement move failed"
fi
[[ "$(bundle_id "${INSTALL_PATH}")" == "rollback-current" ]] || fail "failed rollback did not preserve the current app"
[[ -x "${BACKUP_DIR}/AI Usage Monitor 20990101-000000.app/Contents/MacOS/AI Usage Monitor" ]] \
    || fail "failed rollback discarded its selected backup"
[[ ! -e "${INSTALL_PATH%.app}.incoming.app" && ! -e "${INSTALL_PATH%.app}.outgoing.app" ]] \
    || fail "failed rollback left partial replacement bundles"

echo "Installer and rollback success/failure recovery checks passed."

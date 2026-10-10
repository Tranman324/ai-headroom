# Shared helpers for install.sh and rollback.sh. Expects APP_NAME, INSTALL_PATH, and BACKUP_DIR.
# AI_USAGE_MONITOR_SKIP_LAUNCH=1 skips relaunching (used when rehearsing against a temp folder).

quit_app() {
    local executable="${INSTALL_PATH}/Contents/MacOS/${APP_NAME}"
    # Match the menu-bar app only, not short-lived status-line bridge runs that pass arguments.
    if ! pgrep -fx "${executable}" >/dev/null; then
        return
    fi
    echo "==> Quitting ${APP_NAME}"
    osascript -e "quit app \"${APP_NAME}\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
        pgrep -fx "${executable}" >/dev/null || return 0
        sleep 0.2
    done
    pkill -fx "${executable}" || true
    sleep 1
}

launch_app() {
    if [[ "${AI_USAGE_MONITOR_SKIP_LAUNCH:-0}" != "1" ]]; then
        open "${INSTALL_PATH}"
    fi
}

# Backups are named "<APP_NAME> <yyyymmdd-HHMMSS>.app" (saved by install.sh) or
# "<APP_NAME> replaced <yyyymmdd-HHMMSS>.app" (the build a rollback replaced). Ordering uses the
# timestamp in the name; ditto keeps each bundle's build-time mtime, so mtime is not usable.
install_backups() {
    find "${BACKUP_DIR}" -maxdepth 1 -name "${APP_NAME} [0-9]*.app" 2>/dev/null | sort -r
}

replaced_backups() {
    find "${BACKUP_DIR}" -maxdepth 1 -name "${APP_NAME} replaced [0-9]*.app" 2>/dev/null | sort -r
}

# Prints a backup path that does not exist yet for the given label ("" or "replaced ").
new_backup_path() {
    local label="$1"
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    local candidate="${BACKUP_DIR}/${APP_NAME} ${label}${stamp}.app"
    local counter=1
    while [[ -e "${candidate}" ]]; do
        candidate="${BACKUP_DIR}/${APP_NAME} ${label}${stamp}-${counter}.app"
        counter=$((counter + 1))
    done
    echo "${candidate}"
}

ensure_backup_dir() {
    mkdir -p "${BACKUP_DIR}"
    chmod 700 "${BACKUP_DIR}"
}

# Swaps the bundle into place so a failed copy never leaves the install path without an app.
replace_installed_app() {
    local source_app="$1"
    local incoming="${INSTALL_PATH%.app}.incoming.app"
    local outgoing="${INSTALL_PATH%.app}.outgoing.app"
    rm -rf "${incoming}" "${outgoing}"
    ditto "${source_app}" "${incoming}"
    if [[ -d "${INSTALL_PATH}" ]]; then
        mv "${INSTALL_PATH}" "${outgoing}"
    fi
    if ! mv "${incoming}" "${INSTALL_PATH}"; then
        [[ -d "${outgoing}" ]] && mv "${outgoing}" "${INSTALL_PATH}"
        echo "error: could not install ${source_app}" >&2
        return 1
    fi
    rm -rf "${outgoing}"
}

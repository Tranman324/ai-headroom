# Shared helpers for install.sh and rollback.sh. Expects APP_NAME and INSTALL_PATH.

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

# Swaps the bundle into place so a failed copy never leaves /Applications without an app.
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

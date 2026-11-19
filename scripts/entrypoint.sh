#!/usr/bin/env bash
set -euo pipefail

STEAM_APP_ID=1690800
STEAMCMD_BIN="${STEAMCMD_DIR:-/opt/steamcmd}/steamcmd.sh"
SERVER_DIR="${SERVER_DIR:-/config/gamefiles}"
SAVES_DIR="${SAVES_DIR:-/config/saves}"
SAVED_DIR="${SAVED_DIR:-/config/saved}"
FICSIT_LOCAL_DIR="${FICSIT_LOCAL_DIR:-/config/ficsit/local}"
FICSIT_CACHE_DIR="${FICSIT_CACHE_DIR:-/config/ficsit/cache}"

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
GAME_PORT="${GAME_PORT:-7777}"
RELIABLE_PORT="${RELIABLE_PORT:-8888}"
EXTERNAL_RELIABLE_PORT="${EXTERNAL_RELIABLE_PORT:-}"
MULTIHOME="${MULTIHOME:-0.0.0.0}"
MAX_PLAYERS="${MAX_PLAYERS:-}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
VALIDATE_INSTALL="${VALIDATE_INSTALL:-false}"
STEAM_BETA="${STEAM_BETA:-public}"
STEAM_BETA_PASSWORD="${STEAM_BETA_PASSWORD:-}"
EXTRA_SERVER_ARGS="${EXTRA_SERVER_ARGS:-}"

log() {
    printf '[satisfactory] %s\n' "$*"
}

err() {
    printf '[satisfactory] ERROR: %s\n' "$*" >&2
}

# Step 1: Adjust steam UID/GID and drop privileges if running as root
if [[ "$(id -u)" -eq 0 ]]; then
    current_gid="$(id -g steam)"
    current_uid="$(id -u steam)"

    if [[ "${PGID}" != "${current_gid}" ]]; then
        groupmod -o -g "${PGID}" steam
    fi
    if [[ "${PUID}" != "${current_uid}" ]]; then
        usermod -o -u "${PUID}" steam
    fi

    mkdir -p \
        "${SERVER_DIR}" \
        "${SAVES_DIR}" \
        "${SAVED_DIR}" \
        "${FICSIT_LOCAL_DIR}" \
        "${FICSIT_CACHE_DIR}" \
        "/home/steam/.steam/sdk64" \
        "/home/steam/.config/Epic/FactoryGame"

    chown -R "${PUID}:${PGID}" \
        /home/steam \
        /opt/steamcmd \
        "${SERVER_DIR}" \
        "${SAVES_DIR}" \
        "${SAVED_DIR}" \
        /config/ficsit

    exec gosu steam "$0" "$@"
fi

# Step 2: Configure persistent symlinks for Steam SDK and Unreal Saved/SaveGames
setup_symlinks() {
    mkdir -p /home/steam/.steam/sdk64 /home/steam/.config/Epic/FactoryGame "${SAVES_DIR}" "${SAVED_DIR}"

    if [[ -f /opt/steamcmd/linux64/steamclient.so ]] && [[ ! -e /home/steam/.steam/sdk64/steamclient.so ]]; then
        ln -s /opt/steamcmd/linux64/steamclient.so /home/steam/.steam/sdk64/steamclient.so
    fi

    local epic_saved="/home/steam/.config/Epic/FactoryGame/Saved"
    if [[ ! -L "${epic_saved}" ]]; then
        if [[ -d "${epic_saved}" ]]; then
            cp -an "${epic_saved}/." "${SAVED_DIR}/" || true
            rm -rf "${epic_saved}"
        fi
        ln -s "${SAVED_DIR}" "${epic_saved}"
    fi

    local saved_savegames="${SAVED_DIR}/SaveGames"
    if [[ ! -L "${saved_savegames}" ]]; then
        if [[ -d "${saved_savegames}" ]]; then
            cp -an "${saved_savegames}/." "${SAVES_DIR}/" || true
            rm -rf "${saved_savegames}"
        fi
        ln -s "${SAVES_DIR}" "${saved_savegames}"
    fi
}

read_build_id() {
    local manifest="${SERVER_DIR}/steamapps/appmanifest_${STEAM_APP_ID}.acf"
    if [[ -f "${manifest}" ]]; then
        awk -F'"' '/"buildid"[[:space:]]+"/{print $4; exit}' "${manifest}"
    fi
}

# Step 3: Check and pull latest Satisfactory Dedicated Server via SteamCMD
update_server() {
    local need_install=false
    if [[ ! -f "${SERVER_DIR}/FactoryServer.sh" ]]; then
        need_install=true
    fi

    if [[ "${AUTO_UPDATE,,}" != "true" ]] && [[ "${need_install}" == "false" ]]; then
        log "AUTO_UPDATE=${AUTO_UPDATE}; skipping SteamCMD update check."
        return 0
    fi

    local old_build_id
    old_build_id="$(read_build_id || true)"

    local -a steam_args=(
        +force_install_dir "${SERVER_DIR}"
        +login anonymous
        +app_update "${STEAM_APP_ID}"
    )

    if [[ -n "${STEAM_BETA}" ]] && [[ "${STEAM_BETA}" != "public" ]]; then
        steam_args+=(-beta "${STEAM_BETA}")
        if [[ -n "${STEAM_BETA_PASSWORD}" ]]; then
            steam_args+=(-betapassword "${STEAM_BETA_PASSWORD}")
        fi
    fi

    if [[ "${VALIDATE_INSTALL,,}" == "true" ]] || [[ "${need_install}" == "true" ]]; then
        steam_args+=(validate)
    fi

    steam_args+=(+quit)

    log "Checking for Satisfactory Dedicated Server updates (AppID ${STEAM_APP_ID}, branch=${STEAM_BETA})..."
    "${STEAMCMD_BIN}" "${steam_args[@]}"

    local new_build_id
    new_build_id="$(read_build_id || true)"

    if [[ -z "${old_build_id}" ]] && [[ -n "${new_build_id}" ]]; then
        log "Installed Satisfactory Dedicated Server (build ${new_build_id})."
    elif [[ "${old_build_id}" != "${new_build_id}" ]]; then
        log "Updated Satisfactory Dedicated Server: build ${old_build_id} -> ${new_build_id}."
    else
        log "Satisfactory Dedicated Server is up to date (build ${new_build_id:-unknown})."
    fi
}

SERVER_PID=""

graceful_shutdown() {
    log "Shutdown signal received; stopping Satisfactory Dedicated Server gracefully..."
    if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        pkill -TERM -P "${SERVER_PID}" 2>/dev/null || true
        kill -TERM "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" || true
    fi
    log "Server stopped."
    exit 0
}

main() {
    setup_symlinks
    update_server

    if [[ ! -f "${SERVER_DIR}/FactoryServer.sh" ]]; then
        err "FactoryServer.sh not found in ${SERVER_DIR} after SteamCMD run."
        exit 1
    fi
    chmod +x "${SERVER_DIR}/FactoryServer.sh"

    /usr/local/bin/sync-mods.sh

    local -a server_args=(
        -log
        -unattended
        "-Port=${GAME_PORT}"
        "-ReliablePort=${RELIABLE_PORT}"
    )

    if [[ -n "${EXTERNAL_RELIABLE_PORT}" ]]; then
        server_args+=("-ExternalReliablePort=${EXTERNAL_RELIABLE_PORT}")
    fi

    if [[ -n "${MULTIHOME}" ]]; then
        server_args+=("-multihome=${MULTIHOME}")
    fi

    if [[ -n "${MAX_PLAYERS}" ]]; then
        server_args+=("-ini:Game:[/Script/Engine.GameSession]:MaxPlayers=${MAX_PLAYERS}")
    fi

    if [[ -n "${EXTRA_SERVER_ARGS}" ]]; then
        local -a extra_args=()
        read -r -a extra_args <<< "${EXTRA_SERVER_ARGS}"
        server_args+=("${extra_args[@]}")
    fi

    trap graceful_shutdown SIGTERM SIGINT

    log "Starting Satisfactory Dedicated Server (Port=${GAME_PORT}, ReliablePort=${RELIABLE_PORT})..."
    cd "${SERVER_DIR}"
    ./FactoryServer.sh "${server_args[@]}" &
    SERVER_PID=$!

    local exit_code=0
    wait "${SERVER_PID}" || exit_code=$?
    log "Satisfactory Dedicated Server exited with code ${exit_code}."
    exit "${exit_code}"
}

main "$@"

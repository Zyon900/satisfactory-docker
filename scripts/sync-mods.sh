#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="${SERVER_DIR:-/config/gamefiles}"
MODS_PROFILE_PATH="${MODS_PROFILE_PATH:-/config/mods.smmprofile}"
MODS_ENABLED="${MODS_ENABLED:-true}"
FICSIT_BIN="${FICSIT_BIN:-ficsit}"
FICSIT_LOCAL_DIR="${FICSIT_LOCAL_DIR:-/config/ficsit/local}"
FICSIT_CACHE_DIR="${FICSIT_CACHE_DIR:-/config/ficsit/cache}"
SML_OVERRIDE_ZIP="${SML_OVERRIDE_ZIP:-/opt/sml-override/SML-LinuxServer.zip}"

log() {
    printf '[mods] %s\n' "$*"
}

warn() {
    printf '[mods] WARNING: %s\n' "$*" >&2
}

err() {
    printf '[mods] ERROR: %s\n' "$*" >&2
}

run_ficsit() {
    "${FICSIT_BIN}" \
        --local-dir "${FICSIT_LOCAL_DIR}" \
        --cache-dir "${FICSIT_CACHE_DIR}" \
        --pretty=false \
        "$@"
}

is_installation_registered() {
    local installations_file="${FICSIT_LOCAL_DIR}/installations.json"
    if [[ ! -f "${installations_file}" ]]; then
        return 1
    fi
    jq -e --arg path "${SERVER_DIR}" \
        '(.installations // []) | any(.path == $path)' \
        "${installations_file}" >/dev/null 2>&1
}

ensure_installation_registered() {
    if ! is_installation_registered; then
        log "Registering Satisfactory server installation with ficsit-cli..."
        run_ficsit installation add "${SERVER_DIR}" Default
    fi
}

# Convert an SMM3 JSON profile, simplified JSON ({mods: ...}), or SMM2 ZIP
# into ficsit-cli's profiles.json schema at $2.
# Optionally outputs normalized source JSON (including .lockfile) to $3.
build_ficsit_profiles_json() {
    local profile_path="$1"
    local out_profiles_json="$2"
    local out_source_json="${3:-}"

    local tmp_source
    tmp_source="$(mktemp)"

    # Detect SMM2 ZIP archive (magic bytes "PK")
    local magic=""
    magic="$(head -c 2 "${profile_path}" 2>/dev/null || true)"
    if [[ "${magic}" == "PK" ]]; then
        if ! command -v unzip >/dev/null 2>&1; then
            rm -f "${tmp_source}"
            err "unzip is required to read SMM2 zip profiles."
            return 1
        fi
        local tmp_manifest
        tmp_manifest="$(mktemp)"
        if ! unzip -p "${profile_path}" "manifest.json" > "${tmp_manifest}" 2>/dev/null; then
            rm -f "${tmp_manifest}" "${tmp_source}"
            err "Failed to extract manifest.json from SMM2 zip profile: ${profile_path}"
            return 1
        fi
        if ! jq '
          {
            profile: {
              mods: (
                (.items // [])
                | map(select((.id | ascii_downcase) != "bootstrapper"))
                | map({
                    key: .id,
                    value: {
                      version: ">=0.0.0",
                      enabled: (if .enabled == null then true else .enabled end)
                    }
                  })
                | from_entries
              ),
              name: "Default",
              required_targets: []
            }
          }
        ' "${tmp_manifest}" > "${tmp_source}"; then
            rm -f "${tmp_manifest}" "${tmp_source}"
            err "Failed to parse manifest.json in SMM2 zip profile: ${profile_path}"
            return 1
        fi
        rm -f "${tmp_manifest}"
    else
        if ! jq empty "${profile_path}" >/dev/null 2>&1; then
            rm -f "${tmp_source}"
            err "Invalid JSON in mod profile: ${profile_path}"
            return 1
        fi
        cp "${profile_path}" "${tmp_source}"
    fi

    if [[ -n "${out_source_json}" ]]; then
        cp "${tmp_source}" "${out_source_json}"
    fi

    if ! jq '
      (
        (.profile.mods // .mods // {})
        | with_entries(
            select((.key | ascii_downcase) != "bootstrapper")
            | .value = {
                version: ((.value.version // "") | if . == "" then ">=0.0.0" else . end),
                enabled: (if .value.enabled == null then true else .value.enabled end)
              }
          )
      ) as $mods
      | {
          profiles: {
            Default: {
              mods: $mods,
              name: "Default",
              required_targets: []
            }
          },
          selected_profile: "Default",
          version: 0
        }
    ' "${tmp_source}" > "${out_profiles_json}"; then
        rm -f "${tmp_source}"
        err "Failed to convert mod profile to ficsit-cli format: ${profile_path}"
        return 1
    fi

    rm -f "${tmp_source}"
}

count_enabled_mods() {
    local profiles_json="$1"
    jq '[.profiles.Default.mods | to_entries[] | select(.value.enabled == true)] | length' "${profiles_json}"
}

apply_vanilla_state() {
    local mods_dir="${SERVER_DIR}/FactoryGame/Mods"
    if [[ -d "${mods_dir}" ]] || is_installation_registered; then
        log "Ensuring server is in vanilla mode (cleaning any previously installed mods)..."
        if [[ ! -f "${FICSIT_LOCAL_DIR}/profiles.json" ]]; then
            jq -n '{
              profiles: {
                Default: { mods: {}, name: "Default", required_targets: [] }
              },
              selected_profile: "Default",
              version: 0
            }' > "${FICSIT_LOCAL_DIR}/profiles.json"
        fi
        ensure_installation_registered
        run_ficsit installation set-vanilla "${SERVER_DIR}"
        run_ficsit apply "${SERVER_DIR}"
    else
        log "Vanilla mode active (no mods configured)."
    fi
    rm -f "${FICSIT_LOCAL_DIR}/.smmprofile.sha256"
}

sync_mods() {
    mkdir -p "${FICSIT_LOCAL_DIR}" "${FICSIT_CACHE_DIR}"

    if [[ "${MODS_ENABLED,,}" != "true" ]]; then
        log "MODS_ENABLED=${MODS_ENABLED}; skipping mods and enforcing vanilla state."
        apply_vanilla_state
        return 0
    fi

    if [[ -d "${MODS_PROFILE_PATH}" ]]; then
        err "${MODS_PROFILE_PATH} is a directory! Create a mods.smmprofile file in your compose directory before starting."
        return 1
    fi

    if [[ ! -f "${MODS_PROFILE_PATH}" ]] || [[ ! -s "${MODS_PROFILE_PATH}" ]]; then
        log "No non-empty mod profile found at ${MODS_PROFILE_PATH}."
        apply_vanilla_state
        return 0
    fi

    local tmp_profiles tmp_source
    tmp_profiles="$(mktemp)"
    tmp_source="$(mktemp)"

    if ! build_ficsit_profiles_json "${MODS_PROFILE_PATH}" "${tmp_profiles}" "${tmp_source}"; then
        rm -f "${tmp_profiles}" "${tmp_source}"
        return 1
    fi

    local enabled_count
    enabled_count="$(count_enabled_mods "${tmp_profiles}")"

    if [[ "${enabled_count}" -eq 0 ]]; then
        log "Mod profile ${MODS_PROFILE_PATH} has 0 enabled mods."
        cp "${tmp_profiles}" "${FICSIT_LOCAL_DIR}/profiles.json"
        rm -f "${tmp_profiles}" "${tmp_source}"
        apply_vanilla_state
        return 0
    fi

    log "Found ${enabled_count} enabled mod(s) in ${MODS_PROFILE_PATH}; syncing via ficsit-cli..."
    cp "${tmp_profiles}" "${FICSIT_LOCAL_DIR}/profiles.json"

    ensure_installation_registered
    run_ficsit installation set-profile "${SERVER_DIR}" Default
    run_ficsit installation set-vanilla --off "${SERVER_DIR}"

    local profile_hash prev_hash=""
    profile_hash="$(sha256sum "${MODS_PROFILE_PATH}" | awk '{print $1}')"
    if [[ -f "${FICSIT_LOCAL_DIR}/.smmprofile.sha256" ]]; then
        prev_hash="$(cat "${FICSIT_LOCAL_DIR}/.smmprofile.sha256")"
    fi

    local lockfile_path="${SERVER_DIR}/FactoryGame/Mods/default-lock.json"
    local seeded_lockfile=false

    if [[ "${profile_hash}" != "${prev_hash}" ]]; then
        rm -f "${lockfile_path}"
        if jq -e '(.lockfile.mods // {} | length) > 0' "${tmp_source}" >/dev/null 2>&1; then
            mkdir -p "$(dirname "${lockfile_path}")"
            jq '.lockfile' "${tmp_source}" > "${lockfile_path}"
            seeded_lockfile=true
            log "Seeded lockfile from ${MODS_PROFILE_PATH}."
        fi
    fi

    rm -f "${tmp_profiles}" "${tmp_source}"

    if ! run_ficsit apply "${SERVER_DIR}"; then
        if [[ "${seeded_lockfile}" == "true" ]]; then
            warn "Mod apply with exported lockfile failed; removing seeded lockfile and retrying fresh resolution..."
            rm -f "${lockfile_path}"
            run_ficsit apply "${SERVER_DIR}"
        else
            err "Failed to apply mods from ${MODS_PROFILE_PATH}."
            return 1
        fi
    fi

    if [[ -n "${SML_OVERRIDE_ZIP}" && -f "${SML_OVERRIDE_ZIP}" && -d "${SERVER_DIR}/FactoryGame/Mods/SML" ]]; then
        log "Applying custom SML override from ${SML_OVERRIDE_ZIP}..."
        unzip -qo "${SML_OVERRIDE_ZIP}" -d "${SERVER_DIR}/FactoryGame/Mods/SML"
    fi

    printf '%s\n' "${profile_hash}" > "${FICSIT_LOCAL_DIR}/.smmprofile.sha256"
    log "Mods synchronized successfully."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    sync_mods "$@"
fi

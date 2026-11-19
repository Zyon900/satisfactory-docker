#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="${REPO_DIR}/scripts/sync-mods.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        pass=$((pass + 1))
    else
        echo "FAIL: ${msg} (expected '${expected}', got '${actual}')" >&2
        fail=$((fail + 1))
    fi
}

assert_file_exists() {
    local path="$1"
    local msg="$2"
    if [[ -f "${path}" ]]; then
        pass=$((pass + 1))
    else
        echo "FAIL: ${msg} (missing file: ${path})" >&2
        fail=$((fail + 1))
    fi
}

assert_file_not_exists() {
    local path="$1"
    local msg="$2"
    if [[ ! -e "${path}" ]]; then
        pass=$((pass + 1))
    else
        echo "FAIL: ${msg} (unexpected file exists: ${path})" >&2
        fail=$((fail + 1))
    fi
}

# 1. Syntax check all shell scripts
for script in "${REPO_DIR}/scripts/entrypoint.sh" "${REPO_DIR}/scripts/sync-mods.sh" "${REPO_DIR}/scripts/healthcheck.sh"; do
    bash -n "${script}"
    pass=$((pass + 1))
done

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

create_mock_ficsit() {
    local bin_path="$1"
    cat > "${bin_path}" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

local_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local-dir) local_dir="$2"; shift 2 ;;
        --cache-dir) shift 2 ;;
        --pretty=*) shift ;;
        *) break ;;
    esac
done

cmd="${1:-}"
shift || true

echo "$cmd $*" >> "${MOCK_LOG}"

case "${cmd}" in
    installation)
        sub="${1:-}"
        shift || true
        case "${sub}" in
            add)
                server_path="$1"
                profile="${2:-Default}"
                mkdir -p "${local_dir}"
                jq -n --arg p "${server_path}" --arg pr "${profile}" \
                    '{selected_installation: $p, installations: [{path: $p, profile: $pr, vanilla: false}], version: 0}' \
                    > "${local_dir}/installations.json"
                ;;
            set-profile)
                jq --arg pr "$2" '.installations[0].profile = $pr' \
                    "${local_dir}/installations.json" > "${local_dir}/installations.json.tmp"
                mv "${local_dir}/installations.json.tmp" "${local_dir}/installations.json"
                ;;
            set-vanilla)
                if [[ "${1:-}" == "--off" ]]; then
                    jq '.installations[0].vanilla = false' \
                        "${local_dir}/installations.json" > "${local_dir}/installations.json.tmp"
                else
                    jq '.installations[0].vanilla = true' \
                        "${local_dir}/installations.json" > "${local_dir}/installations.json.tmp"
                fi
                mv "${local_dir}/installations.json.tmp" "${local_dir}/installations.json"
                ;;
        esac
        ;;
    apply)
        server_path="$1"
        if [[ "${FAIL_IF_LOCKFILE:-false}" == "true" ]] && [[ -f "${server_path}/FactoryGame/Mods/default-lock.json" ]]; then
            exit 1
        fi
        vanilla="$(jq -r '.installations[0].vanilla' "${local_dir}/installations.json")"
        if [[ "${vanilla}" == "true" ]]; then
            rm -rf "${server_path}/FactoryGame/Mods"
        else
            mkdir -p "${server_path}/FactoryGame/Mods"
        fi
        ;;
esac
EOF
    chmod +x "${bin_path}"
}

MOCK_FICSIT="${TMP_ROOT}/ficsit"
create_mock_ficsit "${MOCK_FICSIT}"

# 2. Test empty default mods.smmprofile (vanilla fast-path)
T1="${TMP_ROOT}/t1"
mkdir -p "${T1}/server" "${T1}/local" "${T1}/cache"
export MOCK_LOG="${T1}/calls.log"
: > "${MOCK_LOG}"
SERVER_DIR="${T1}/server" \
MODS_PROFILE_PATH="${REPO_DIR}/mods.smmprofile" \
MODS_ENABLED="true" \
FICSIT_BIN="${MOCK_FICSIT}" \
FICSIT_LOCAL_DIR="${T1}/local" \
FICSIT_CACHE_DIR="${T1}/cache" \
    bash "${SYNC_SCRIPT}"
assert_eq "$(wc -l < "${MOCK_LOG}")" "0" "Empty default profile does not invoke ficsit when no Mods dir exists"

# 3. Test SMM3 exported profile with enabled/disabled mods, Bootstrapper, and lockfile
T2="${TMP_ROOT}/t2"
mkdir -p "${T2}/server" "${T2}/local" "${T2}/cache"
export MOCK_LOG="${T2}/calls.log"
: > "${MOCK_LOG}"
cat > "${T2}/mods.smmprofile" << 'EOF'
{
  "profile": {
    "mods": {
      "Bootstrapper": { "version": ">=1.0.0", "enabled": true },
      "EfficiencyCheckerMod": { "version": ">=2.0.0", "enabled": true },
      "DisabledMod": { "version": "", "enabled": false }
    },
    "name": "ClientProfile",
    "required_targets": ["Windows"]
  },
  "lockfile": {
    "mods": {
      "EfficiencyCheckerMod": { "version": "2.1.0" }
    },
    "version": 1
  },
  "metadata": { "gameVersion": 368883 }
}
EOF
SERVER_DIR="${T2}/server" \
MODS_PROFILE_PATH="${T2}/mods.smmprofile" \
MODS_ENABLED="true" \
FICSIT_BIN="${MOCK_FICSIT}" \
FICSIT_LOCAL_DIR="${T2}/local" \
FICSIT_CACHE_DIR="${T2}/cache" \
    bash "${SYNC_SCRIPT}"

assert_file_exists "${T2}/local/profiles.json" "profiles.json generated"
assert_eq "$(jq -r '.profiles.Default.mods.Bootstrapper // "missing"' "${T2}/local/profiles.json")" "missing" "Bootstrapper stripped"
assert_eq "$(jq -r '.profiles.Default.mods.EfficiencyCheckerMod.enabled' "${T2}/local/profiles.json")" "true" "Enabled mod preserved"
assert_eq "$(jq -r '.profiles.Default.mods.DisabledMod.version' "${T2}/local/profiles.json")" ">=0.0.0" "Empty version normalized"
assert_eq "$(jq -r '.profiles.Default.required_targets | length' "${T2}/local/profiles.json")" "0" "required_targets cleared for server compatibility"
assert_file_exists "${T2}/server/FactoryGame/Mods/default-lock.json" "Lockfile seeded from .smmprofile"
assert_eq "$(jq -r '.installations[0].vanilla' "${T2}/local/installations.json")" "false" "Vanilla disabled when mods active"

# 4. Test switching to MODS_ENABLED=false strips mods back to vanilla
: > "${MOCK_LOG}"
SERVER_DIR="${T2}/server" \
MODS_PROFILE_PATH="${T2}/mods.smmprofile" \
MODS_ENABLED="false" \
FICSIT_BIN="${MOCK_FICSIT}" \
FICSIT_LOCAL_DIR="${T2}/local" \
FICSIT_CACHE_DIR="${T2}/cache" \
    bash "${SYNC_SCRIPT}"
assert_eq "$(jq -r '.installations[0].vanilla' "${T2}/local/installations.json")" "true" "MODS_ENABLED=false switches to vanilla"
assert_file_not_exists "${T2}/server/FactoryGame/Mods" "Vanilla apply removed Mods directory"

# 5. Test seeded lockfile fallback retry when lockfile fails resolution
T3="${TMP_ROOT}/t3"
mkdir -p "${T3}/server" "${T3}/local" "${T3}/cache"
export MOCK_LOG="${T3}/calls.log"
: > "${MOCK_LOG}"
FAIL_IF_LOCKFILE="true" \
SERVER_DIR="${T3}/server" \
MODS_PROFILE_PATH="${T2}/mods.smmprofile" \
MODS_ENABLED="true" \
FICSIT_BIN="${MOCK_FICSIT}" \
FICSIT_LOCAL_DIR="${T3}/local" \
FICSIT_CACHE_DIR="${T3}/cache" \
    bash "${SYNC_SCRIPT}"
assert_eq "$(grep -c '^apply ' "${MOCK_LOG}")" "2" "Retried apply once without seeded lockfile"
assert_file_not_exists "${T3}/server/FactoryGame/Mods/default-lock.json" "Bad seeded lockfile removed before retry"

# 6. Test SMM2 ZIP profile support
T4="${TMP_ROOT}/t4"
mkdir -p "${T4}/server" "${T4}/local" "${T4}/cache"
export MOCK_LOG="${T4}/calls.log"
: > "${MOCK_LOG}"
cat > "${T4}/manifest.json" << 'EOF'
{"items":[{"id":"Bootstrapper","enabled":true},{"id":"AreaActions","enabled":true}]}
EOF
python3 - "${T4}/manifest.json" "${T4}/smm2.smmprofile" << 'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], "w") as zf:
    zf.write(sys.argv[1], "manifest.json")
PY
SERVER_DIR="${T4}/server" \
MODS_PROFILE_PATH="${T4}/smm2.smmprofile" \
MODS_ENABLED="true" \
FICSIT_BIN="${MOCK_FICSIT}" \
FICSIT_LOCAL_DIR="${T4}/local" \
FICSIT_CACHE_DIR="${T4}/cache" \
    bash "${SYNC_SCRIPT}"
assert_eq "$(jq -r '.profiles.Default.mods.AreaActions.enabled' "${T4}/local/profiles.json")" "true" "SMM2 zip profile parsed"

# 7. Test directory guard for MODS_PROFILE_PATH
T5="${TMP_ROOT}/t5"
mkdir -p "${T5}/server" "${T5}/local" "${T5}/cache" "${T5}/mods.smmprofile"
if SERVER_DIR="${T5}/server" \
    MODS_PROFILE_PATH="${T5}/mods.smmprofile" \
    MODS_ENABLED="true" \
    FICSIT_BIN="${MOCK_FICSIT}" \
    FICSIT_LOCAL_DIR="${T5}/local" \
    FICSIT_CACHE_DIR="${T5}/cache" \
    bash "${SYNC_SCRIPT}" 2>/dev/null; then
    echo "FAIL: Expected directory MODS_PROFILE_PATH to fail" >&2
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi

echo "Tests passed: ${pass}, failed: ${fail}"
[[ "${fail}" -eq 0 ]]

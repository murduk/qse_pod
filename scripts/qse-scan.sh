#!/usr/bin/env bash
# =============================================================================
# qse-scan.sh - Run an IBM Quantum Safe Explorer (QSE) scan on ONE local
# directory (typically the GitHub Actions workspace) and optionally upload
# the findings to Guardium Cryptography Manager (GCM).
#
# Installed in the image as /usr/local/bin/qse-scan.
#
# Usage:
#   qse-scan [SCAN_DIR]
#
# Environment variables (all optional; GitHub Actions defaults in brackets):
#   SCAN_DIR            Directory to scan              [$GITHUB_WORKSPACE or $PWD]
#   OUTPUT_DIR          Where QSE writes its results   [${RUNNER_TEMP:-/tmp}/qse-results]
#   APP_NAME            Application label              [repo name / dir name]
#   APP_VERSION         Version label                  [short commit SHA]
#   REPO_URL            Repo URL sent to GCM           [$GITHUB_SERVER_URL/$GITHUB_REPOSITORY]
#   LANGUAGES           Comma-separated override, e.g. ".java,.py"  [auto-detect]
#   SCAN_ALL_LANGUAGES  "true" to scan every QSE language           [false]
#   EXCLUDE_PATHS       Comma-separated paths passed to -ef
#                       [src/test,vendor,node_modules,.git,venv,.venv,.qse-venv]
#   SKIP_BUILD          "true" to skip pre-compilation (caller built already) [false]
#   PY_MODULE_PATH      Path(s) passed to -py_module_path  [.qse-venv site-packages if created]
#   UPLOAD_TO_GCM       auto | true | false                [auto]
#                         auto  = upload only when GCM_SERVER_URL + GCM_BEARER_TOKEN set
#                         true  = upload; missing GCM config is an error
#   GCM_SERVER_URL      GCM base URL, e.g. https://gcm.example.com
#   GCM_BEARER_TOKEN    Bearer token for the GCM API (never logged)
#   FAIL_ON_CRITICAL    "true" to exit 2 when weak algorithms are found [false]
#
# Exit codes:
#   0 success | 1 scan or upload failure | 2 critical findings with FAIL_ON_CRITICAL=true
#
# GitHub Actions integration:
#   Writes results_dir, critical_found, upload_status to $GITHUB_OUTPUT and a
#   markdown summary to $GITHUB_STEP_SUMMARY when those files are available.
#
# Changes:
#   2026-08-21 - Initial creation (multi-repo K8s CronJob scanner, scan.sh)
#   2026-08-22 - Bearer token auth, discovery/analytics upload endpoints
#   2026-11-11 - Rewritten as single-directory scanner for GitHub Actions;
#                removed K8s/multi-repo/commit-tracking logic
# =============================================================================

set -euo pipefail

# ---- Constants ---------------------------------------------------------------
readonly TIMESTAMP_FORMAT='%Y-%m-%dT%H:%M:%S%z'
readonly QSE_HOME="${QSE_HOME:-/opt/qse}"
readonly QSE_CLI="${QSE_HOME}/cli.sh"
readonly MAX_RETRIES=3
readonly RETRY_BASE_DELAY=5
readonly ALL_LANGUAGES=(".java" ".go" ".py" ".cpp" ".cs" ".dart")
readonly DEFAULT_EXCLUDES="src/test,vendor,node_modules,.git,venv,.venv,.qse-venv"
readonly CRITICAL_PATTERN='MD5|SHA-1|SHA1|DES|3DES|RC4|RSA-1024'

# ---- Logging: timestamp-prefixed output to stderr ----------------------------
log()   { echo "[$(date +"${TIMESTAMP_FORMAT}")] [$1] ${*:2}" >&2; }
info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

usage() { sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---- GitHub Actions helpers --------------------------------------------------
gh_output() {
    [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
}
gh_summary() {
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
    echo "$*" >> "${GITHUB_STEP_SUMMARY}"
}

# ---- Resolve configuration ---------------------------------------------------
resolve_config() {
    SCAN_DIR="${1:-${SCAN_DIR:-${GITHUB_WORKSPACE:-${PWD}}}}"
    if [[ ! -d "${SCAN_DIR}" ]]; then
        error "Scan directory does not exist: ${SCAN_DIR}"
        exit 1
    fi
    SCAN_DIR="$(cd "${SCAN_DIR}" && pwd)"

    OUTPUT_DIR="${OUTPUT_DIR:-${RUNNER_TEMP:-/tmp}/qse-results}"
    mkdir -p "${OUTPUT_DIR}"
    OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

    if [[ -z "${APP_NAME:-}" ]]; then
        if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
            APP_NAME="${GITHUB_REPOSITORY##*/}"
        else
            APP_NAME="$(basename "${SCAN_DIR}")"
        fi
    fi

    if [[ -z "${APP_VERSION:-}" ]]; then
        if [[ -n "${GITHUB_SHA:-}" ]]; then
            APP_VERSION="${GITHUB_SHA:0:7}"
        else
            APP_VERSION="$(git -C "${SCAN_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
        fi
    fi

    if [[ -z "${REPO_URL:-}" ]]; then
        if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
            REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}"
        else
            # Strip any embedded credentials (https://user:token@host/...)
            REPO_URL="$(git -C "${SCAN_DIR}" remote get-url origin 2>/dev/null \
                | sed -E 's#(https?://)[^@/]+@#\1#' || true)"
            REPO_URL="${REPO_URL:-${APP_NAME}}"
        fi
    fi

    EXCLUDE_PATHS="${EXCLUDE_PATHS:-${DEFAULT_EXCLUDES}}"
    UPLOAD_TO_GCM="${UPLOAD_TO_GCM:-auto}"
    FAIL_ON_CRITICAL="${FAIL_ON_CRITICAL:-false}"
    SKIP_BUILD="${SKIP_BUILD:-false}"
    SCAN_ALL_LANGUAGES="${SCAN_ALL_LANGUAGES:-false}"
    PY_VENV_SITE_PACKAGES=""
    CRITICAL_FOUND=false
    UPLOAD_STATUS="skipped"

    if [[ ! -x "${QSE_CLI}" ]]; then
        error "QSE CLI not found or not executable: ${QSE_CLI}"
        exit 1
    fi

    # Decide upload mode up front so misconfiguration fails before a long scan
    case "${UPLOAD_TO_GCM}" in
        auto)
            if [[ -n "${GCM_SERVER_URL:-}" && -n "${GCM_BEARER_TOKEN:-}" ]]; then
                DO_UPLOAD=true
            else
                DO_UPLOAD=false
                info "GCM_SERVER_URL/GCM_BEARER_TOKEN not set — GCM upload will be skipped."
            fi ;;
        true)
            DO_UPLOAD=true
            for var in GCM_SERVER_URL GCM_BEARER_TOKEN; do
                if [[ -z "${!var:-}" ]]; then
                    error "UPLOAD_TO_GCM=true but '${var}' is not set."
                    exit 1
                fi
            done ;;
        false) DO_UPLOAD=false ;;
        *)
            error "Invalid UPLOAD_TO_GCM='${UPLOAD_TO_GCM}' (expected auto|true|false)."
            exit 1 ;;
    esac
}

# ---- Inspect repo and set DETECTED_LANGUAGES + build flags -------------------
# Sets globals: DETECTED_LANGUAGES[], NEEDS_JAVA_BUILD, NEEDS_GO_BUILD,
#               NEEDS_CPP_BUILD, NEEDS_DOTNET_BUILD, NEEDS_DART_BUILD, NEEDS_PYTHON_DEPS
# Uses -print -quit (not `| grep -q`) so a large tree can't SIGPIPE find and
# trip pipefail. Skips VCS, virtualenv and vendored dependency directories.
has_files() {
    local dir="$1"; shift
    local hit
    hit=$(find "${dir}" \
        \( -name .git -o -name .qse-venv -o -name venv -o -name .venv \
           -o -name node_modules -o -name vendor \) -prune \
        -o \( "$@" \) -print -quit 2>/dev/null || true)
    [[ -n "${hit}" ]]
}

detect_languages() {
    local repo_dir="$1"
    DETECTED_LANGUAGES=()
    NEEDS_JAVA_BUILD=false
    NEEDS_GO_BUILD=false
    NEEDS_CPP_BUILD=false
    NEEDS_DOTNET_BUILD=false
    NEEDS_DART_BUILD=false
    NEEDS_PYTHON_DEPS=false

    if has_files "${repo_dir}" -name "*.java" -o -name "pom.xml" \
            -o -name "build.gradle" -o -name "build.gradle.kts"; then
        DETECTED_LANGUAGES+=(".java"); NEEDS_JAVA_BUILD=true
        info "Detected language: Java"
    fi

    if has_files "${repo_dir}" -name "*.go" -o -name "go.mod"; then
        DETECTED_LANGUAGES+=(".go"); NEEDS_GO_BUILD=true
        info "Detected language: Go"
    fi

    if has_files "${repo_dir}" -name "*.py" -o -name "requirements.txt" \
            -o -name "pyproject.toml" -o -name "setup.py"; then
        DETECTED_LANGUAGES+=(".py"); NEEDS_PYTHON_DEPS=true
        info "Detected language: Python"
    fi

    if has_files "${repo_dir}" -name "*.cpp" -o -name "*.cc" -o -name "*.cxx" \
            -o -name "CMakeLists.txt" -o -name "Makefile"; then
        DETECTED_LANGUAGES+=(".cpp"); NEEDS_CPP_BUILD=true
        info "Detected language: C/C++"
    fi

    if has_files "${repo_dir}" -name "*.cs" -o -name "*.csproj" -o -name "*.sln"; then
        DETECTED_LANGUAGES+=(".cs"); NEEDS_DOTNET_BUILD=true
        info "Detected language: C#/.NET"
    fi

    if has_files "${repo_dir}" -name "*.dart" -o -name "pubspec.yaml"; then
        DETECTED_LANGUAGES+=(".dart"); NEEDS_DART_BUILD=true
        info "Detected language: Dart"
    fi

    # Explicit overrides
    if [[ -n "${LANGUAGES:-}" ]]; then
        IFS=',' read -r -a DETECTED_LANGUAGES <<< "${LANGUAGES// /}"
        info "LANGUAGES override: ${LANGUAGES}"
    elif [[ "${SCAN_ALL_LANGUAGES}" == "true" ]]; then
        DETECTED_LANGUAGES=("${ALL_LANGUAGES[@]}")
        info "SCAN_ALL_LANGUAGES=true — scanning all supported languages."
    elif [[ "${#DETECTED_LANGUAGES[@]}" -eq 0 ]]; then
        warn "No recognised languages detected — falling back to all supported extensions."
        DETECTED_LANGUAGES=("${ALL_LANGUAGES[@]}")
    fi

    info "Languages to scan: ${DETECTED_LANGUAGES[*]}"
}

has_language() {
    [[ " ${DETECTED_LANGUAGES[*]} " == *" $1 "* ]]
}

# ---- Maven/Gradle/javac pre-compile ------------------------------------------
compile_java() {
    local repo_dir="$1"
    info "--- Java: pre-compilation ---"
    if [[ -f "${repo_dir}/pom.xml" ]]; then
        info "Maven project detected."
        mvn -f "${repo_dir}/pom.xml" clean install dependency:copy-dependencies \
            -DskipTests -q --batch-mode \
            || { warn "Maven build failed — QSE will scan without compiled classes."; return 0; }
    elif [[ -f "${repo_dir}/build.gradle" || -f "${repo_dir}/build.gradle.kts" ]]; then
        info "Gradle project detected."
        local gradle_cmd="gradle"
        [[ -x "${repo_dir}/gradlew" ]] && gradle_cmd="${repo_dir}/gradlew"
        "${gradle_cmd}" -p "${repo_dir}" build -x test --no-daemon --quiet \
            || { warn "Gradle build failed — QSE will scan without compiled classes."; return 0; }
    else
        info "No build descriptor found — compiling with javac."
        local out_dir="${repo_dir}/target/classes"
        mkdir -p "${out_dir}"
        find "${repo_dir}" -name "*.java" -print0 \
            | xargs -0 -r javac -d "${out_dir}" 2>/dev/null \
            || warn "javac errors — partial class files may exist."
    fi
    info "Java compilation complete."
}

# ---- go build pre-compile ----------------------------------------------------
compile_go() {
    local repo_dir="$1"
    info "--- Go: pre-compilation ---"
    if [[ -f "${repo_dir}/go.mod" ]]; then
        info "go.mod detected — running go build ./..."
        ( cd "${repo_dir}" && go build ./... ) \
            || warn "Go build errors — QSE will scan source directly."
    else
        info "No go.mod — scanning source files directly."
    fi
    info "Go compilation done."
}

# ---- CMake or make pre-compile -----------------------------------------------
compile_cpp() {
    local repo_dir="$1"
    info "--- C/C++: pre-compilation ---"
    if [[ -f "${repo_dir}/CMakeLists.txt" ]]; then
        local build_dir="${repo_dir}/build"
        mkdir -p "${build_dir}"
        { cmake -S "${repo_dir}" -B "${build_dir}" -DCMAKE_BUILD_TYPE=Release -Wno-dev \
            && cmake --build "${build_dir}" --parallel "$(nproc)"; } \
            || warn "CMake errors — QSE will scan source files."
    elif [[ -f "${repo_dir}/Makefile" ]]; then
        ( cd "${repo_dir}" && make -j"$(nproc)" ) \
            || warn "make errors — QSE will scan source files."
    else
        info "No CMake/Makefile — QSE will scan source files directly."
    fi
    info "C/C++ compilation done."
}

# ---- dotnet build pre-compile ------------------------------------------------
compile_dotnet() {
    local repo_dir="$1"
    info "--- C#/.NET: pre-compilation ---"
    local proj_file
    proj_file=$(find "${repo_dir}" -maxdepth 3 \
        \( -name "*.sln" -o -name "*.csproj" \) | head -1)
    if [[ -n "${proj_file}" ]]; then
        dotnet build "${proj_file}" --configuration Release -v quiet \
            || warn "dotnet build errors — QSE will scan source files."
    else
        info "No .sln/.csproj found — QSE will scan source files directly."
    fi
    info ".NET compilation done."
}

# ---- pip install Python dependencies before scan -----------------------------
# Installs into <repo>/.qse-venv and records its site-packages path so it can
# be passed to QSE as -py_module_path when PY_MODULE_PATH is not set.
compile_python() {
    local repo_dir="$1"
    info "--- Python: dependency installation ---"

    if [[ ! -f "${repo_dir}/requirements.txt" && ! -f "${repo_dir}/pyproject.toml" \
            && ! -f "${repo_dir}/setup.py" ]]; then
        info "No requirements.txt/pyproject.toml/setup.py — skipping pip install."
        return 0
    fi

    local venv_dir="${repo_dir}/.qse-venv"
    python3 -m venv "${venv_dir}" \
        || { warn "Could not create Python venv — skipping pip install."; return 0; }

    local pip="${venv_dir}/bin/pip"

    if [[ -f "${repo_dir}/requirements.txt" ]]; then
        info "Installing from requirements.txt..."
        "${pip}" install --quiet -r "${repo_dir}/requirements.txt" \
            || warn "pip install requirements.txt had errors (non-fatal)."
    fi

    if [[ -f "${repo_dir}/pyproject.toml" ]] || [[ -f "${repo_dir}/setup.py" ]]; then
        info "Installing package in editable mode..."
        "${pip}" install --quiet -e "${repo_dir}" \
            || warn "pip install -e had errors (non-fatal)."
    fi

    local sp
    for sp in "${venv_dir}"/lib/python3*/site-packages; do
        [[ -d "${sp}" ]] && PY_VENV_SITE_PACKAGES="${sp}"
    done

    info "Python dependency step done."
}

# ---- dart pub get dependency fetch -------------------------------------------
compile_dart() {
    local repo_dir="$1"
    info "--- Dart: dependency resolution ---"
    if [[ -f "${repo_dir}/pubspec.yaml" ]]; then
        ( cd "${repo_dir}" && dart pub get ) \
            || warn "dart pub get failed — QSE will scan source files."
    fi
    info "Dart dependency step done."
}

pre_compile() {
    local repo_dir="$1"
    if [[ "${SKIP_BUILD}" == "true" ]]; then
        info "SKIP_BUILD=true — skipping pre-compilation."
        return 0
    fi
    if [[ "${NEEDS_JAVA_BUILD}"   == "true" ]] && has_language .java; then compile_java   "${repo_dir}"; fi
    if [[ "${NEEDS_GO_BUILD}"     == "true" ]] && has_language .go;   then compile_go     "${repo_dir}"; fi
    if [[ "${NEEDS_PYTHON_DEPS}"  == "true" ]] && has_language .py;   then compile_python "${repo_dir}"; fi
    if [[ "${NEEDS_CPP_BUILD}"    == "true" ]] && has_language .cpp;  then compile_cpp    "${repo_dir}"; fi
    if [[ "${NEEDS_DOTNET_BUILD}" == "true" ]] && has_language .cs;   then compile_dotnet "${repo_dir}"; fi
    if [[ "${NEEDS_DART_BUILD}"   == "true" ]] && has_language .dart; then compile_dart   "${repo_dir}"; fi
    return 0
}

# ---- Build the comma-separated -l flag value ---------------------------------
build_language_flag() {
    local result
    printf -v result '%s,' "${DETECTED_LANGUAGES[@]}"
    echo "${result%,}"
}

# ---- Build -cf value from compiled Java artefact dirs ------------------------
build_java_cf_flag() {
    local repo_dir="$1"
    local cf_parts=()
    [[ -d "${repo_dir}/target/classes" ]]    && cf_parts+=("${repo_dir}/target/classes")
    [[ -d "${repo_dir}/target/dependency" ]] && cf_parts+=("${repo_dir}/target/dependency")
    [[ -d "${repo_dir}/build/classes" ]]     && cf_parts+=("${repo_dir}/build/classes")
    [[ -d "${repo_dir}/build/libs" ]]        && cf_parts+=("${repo_dir}/build/libs")
    if [[ "${#cf_parts[@]}" -gt 0 ]]; then
        local result
        printf -v result '%s;' "${cf_parts[@]}"
        echo "${result%;}"
    fi
}

# ---- Run the QSE CLI with all detected language flags ------------------------
run_qse_scan() {
    local repo_dir="$1" output_dir="$2"
    local lang_flag
    lang_flag=$(build_language_flag)

    info "Starting QSE scan..."
    info "  App      : ${APP_NAME} @ ${APP_VERSION}"
    info "  Languages: ${lang_flag}"
    info "  Input    : ${repo_dir}"
    info "  Output   : ${output_dir}"

    local cli_args=(
        -i       "${repo_dir}"       # input folder
        -l       "${lang_flag}"      # language extensions to scan
        -o       "${output_dir}"     # output folder
        -app     "${APP_NAME}"       # application name label
        -app_ver "${APP_VERSION}"    # version label
        -log                         # enable detailed log output
    )

    if [[ -n "${EXCLUDE_PATHS}" ]]; then
        cli_args+=(-ef "${EXCLUDE_PATHS}")
        info "  Exclusions: ${EXCLUDE_PATHS}"
    fi

    local use_da=false

    # Python: Usage Analysis (-da) always; module path if configured or venv created
    if has_language .py; then
        use_da=true
        local py_path="${PY_MODULE_PATH:-${PY_VENV_SITE_PACKAGES}}"
        if [[ -n "${py_path}" ]]; then
            cli_args+=(-py_module_path "${py_path}")
            info "  Python -py_module_path: ${py_path}"
        fi
    fi

    # Java: Usage Analysis (-da) + class/dep paths (-cf) when compiled output exists
    if has_language .java; then
        local cf_flag
        cf_flag=$(build_java_cf_flag "${repo_dir}")
        if [[ -n "${cf_flag}" ]]; then
            use_da=true
            cli_args+=(-cf "${cf_flag}")
            info "  Java -cf : ${cf_flag}"
        fi
    fi

    [[ "${use_da}" == "true" ]] && cli_args+=(-da)

    # Dart: exact package name matching
    has_language .dart && cli_args+=(-em true)

    info "Executing: ${QSE_CLI} ${cli_args[*]}"
    local rc=0
    ( cd "${QSE_HOME}" && "${QSE_CLI}" "${cli_args[@]}" ) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        error "QSE CLI exited with code ${rc}"
        return "${rc}"
    fi
    info "QSE scan completed. Results: ${output_dir}"
}

# ---- Grep results for known weak algorithms ----------------------------------
check_critical_findings() {
    local output_dir="$1"
    info "Checking results for critical cryptographic findings..."
    local hits
    hits=$(find "${output_dir}" -name "*.json" -print0 \
        | xargs -0 -r grep -lwE "${CRITICAL_PATTERN}" 2>/dev/null || true)
    if [[ -n "${hits}" ]]; then
        CRITICAL_FOUND=true
        warn "Critical findings detected (${CRITICAL_PATTERN//|//}). Files:"
        while IFS= read -r f; do warn "  ${f}"; done <<< "${hits}"
    else
        info "No critical cryptographic findings."
    fi
}

# ---- Internal: POST a single findings file to a GCM endpoint -----------------
# Auth: Authorization: Bearer <GCM_BEARER_TOKEN> + token_type: api_key header
# Retry: exponential backoff on 5xx / curl errors; no retry on 4xx
_gcm_post_file() {
    local endpoint="$1" findings_file="$2"
    local attempt=0 delay="${RETRY_BASE_DELAY}" http_code

    info "Uploading to GCM endpoint: ${endpoint}"
    info "  Findings file: ${findings_file}"

    while [[ "${attempt}" -lt "${MAX_RETRIES}" ]]; do
        attempt=$(( attempt + 1 ))
        info "  Attempt ${attempt}/${MAX_RETRIES}..."

        local resp_file curl_rc=0 resp_body
        resp_file=$(mktemp)

        http_code=$(curl --silent --show-error \
            --write-out "%{http_code}" \
            --output "${resp_file}" \
            --max-time 120 \
            -X POST "${endpoint}" \
            -H "accept: application/json" \
            -H "Authorization: Bearer ${GCM_BEARER_TOKEN}" \
            -H "token_type: api_key" \
            -F "file=@${findings_file};type=application/json" \
        ) || curl_rc=$?
        resp_body=$(cat "${resp_file}"); rm -f "${resp_file}"

        if [[ "${curl_rc}" -ne 0 ]]; then
            warn "curl error (exit ${curl_rc}) on attempt ${attempt}."
        elif [[ "${http_code}" =~ ^2 ]]; then
            info "GCM upload successful (HTTP ${http_code})."
            return 0
        elif [[ "${http_code}" =~ ^4 ]]; then
            error "GCM client error HTTP ${http_code}: ${resp_body}"
            error "Not retrying 4xx errors."
            return 1
        else
            warn "GCM returned HTTP ${http_code}: ${resp_body}"
        fi

        if [[ "${attempt}" -lt "${MAX_RETRIES}" ]]; then
            info "Retrying in ${delay}s..."
            sleep "${delay}"
            delay=$(( delay * 2 ))
        fi
    done

    error "GCM upload failed after ${MAX_RETRIES} attempts."
    return 1
}

# ---- Upload findings files to GCM --------------------------------------------
#   quantum_safe_api_discovery_findings.json            → /upload-qse-findings/discovery
#   quantum_safe_cryptography_analysis_findings_*.json  → /upload-qse-findings/analytics
upload_to_gcm() {
    local output_dir="$1" repo_url="$2"
    local base_url="${GCM_SERVER_URL%/}/ibm/pv/api/v1/upload-qse-findings"

    local encoded_url
    encoded_url=$(python3 -c \
        "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" \
        "${repo_url}")

    local uploaded=0

    local discovery_file
    discovery_file=$(find "${output_dir}" -maxdepth 2 \
        -name "quantum_safe_api_discovery_findings.json" | head -1)
    if [[ -n "${discovery_file}" ]]; then
        _gcm_post_file \
            "${base_url}/discovery?repositoryUrl=${encoded_url}" \
            "${discovery_file}" || return 1
        uploaded=$(( uploaded + 1 ))
    fi

    local analytics_file
    while IFS= read -r analytics_file; do
        [[ -n "${analytics_file}" ]] || continue
        _gcm_post_file \
            "${base_url}/analytics?repositoryUrl=${encoded_url}" \
            "${analytics_file}" || return 1
        uploaded=$(( uploaded + 1 ))
    done < <(find "${output_dir}" -maxdepth 2 \
        -name "quantum_safe_cryptography_analysis_findings_*.json")

    if [[ "${uploaded}" -eq 0 ]]; then
        warn "No findings files found in ${output_dir} — nothing uploaded."
        UPLOAD_STATUS="nothing-to-upload"
        return 0
    fi

    UPLOAD_STATUS="uploaded (${uploaded} file(s))"
    info "GCM upload complete — ${uploaded} file(s) uploaded."
}

# ---- Job summary -------------------------------------------------------------
write_summary() {
    local scan_status="$1"
    gh_output results_dir "${OUTPUT_DIR}"
    gh_output critical_found "${CRITICAL_FOUND}"
    gh_output upload_status "${UPLOAD_STATUS}"

    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
    local critical_label="No"
    [[ "${CRITICAL_FOUND}" == "true" ]] && critical_label="**Yes** (${CRITICAL_PATTERN//|/, })"
    gh_summary "## Quantum Safe Explorer scan"
    gh_summary ""
    gh_summary "| | |"
    gh_summary "|---|---|"
    gh_summary "| Application | \`${APP_NAME}\` @ \`${APP_VERSION}\` |"
    gh_summary "| Languages | \`$(build_language_flag)\` |"
    gh_summary "| Scan | ${scan_status} |"
    gh_summary "| Critical findings | ${critical_label} |"
    gh_summary "| GCM upload | ${UPLOAD_STATUS} |"
    gh_summary ""
    gh_summary "Result files:"
    gh_summary ""
    local f
    while IFS= read -r f; do
        [[ -n "${f}" ]] && gh_summary "- \`${f#"${OUTPUT_DIR}"/}\`"
    done < <(find "${OUTPUT_DIR}" -type f -name "*.json" | sort)
}

# ---- Entry point -------------------------------------------------------------
main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac

    resolve_config "${1:-}"

    info "=========================================="
    info "QSE scan starting"
    info "  Scan dir   : ${SCAN_DIR}"
    info "  Output dir : ${OUTPUT_DIR}"
    info "  Repo URL   : ${REPO_URL}"
    info "  GCM upload : ${DO_UPLOAD}"
    info "=========================================="

    info "Step 1/4: Detecting languages and pre-compiling..."
    detect_languages "${SCAN_DIR}"
    pre_compile "${SCAN_DIR}"

    info "Step 2/4: Running QSE cryptographic scan..."
    if ! run_qse_scan "${SCAN_DIR}" "${OUTPUT_DIR}"; then
        write_summary "failed"
        exit 1
    fi

    info "Step 3/4: Checking for critical findings..."
    check_critical_findings "${OUTPUT_DIR}"

    local upload_failed=false
    if [[ "${DO_UPLOAD}" == "true" ]]; then
        info "Step 4/4: Uploading results to GCM..."
        if ! upload_to_gcm "${OUTPUT_DIR}" "${REPO_URL}"; then
            UPLOAD_STATUS="failed"
            upload_failed=true
        fi
    else
        info "Step 4/4: GCM upload skipped."
    fi

    write_summary "completed"

    if [[ "${upload_failed}" == "true" ]]; then
        error "GCM upload failed."
        exit 1
    fi
    if [[ "${CRITICAL_FOUND}" == "true" && "${FAIL_ON_CRITICAL}" == "true" ]]; then
        error "Critical cryptographic findings detected and FAIL_ON_CRITICAL=true."
        exit 2
    fi
    info "QSE scan finished successfully."
}

main "$@"

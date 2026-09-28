#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="1.0.0"
HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
DATE_STAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="./inventory-${HOSTNAME}-${DATE_STAMP}.json"

usage() {
    cat <<EOF
Amazon Linux Discovery Script v${SCRIPT_VERSION}

Collects a full package and runtime inventory from an Amazon Linux instance
for migration planning to RHEL.

Usage: $(basename "$0") [-o OUTPUT_FILE] [-h]

Options:
  -o FILE   Output file path (default: ${OUTPUT_FILE})
  -h        Show this help message

Requirements:
  - Amazon Linux 2 or Amazon Linux 2023
  - Root/sudo recommended for full service and network visibility
  - No external dependencies (jq used if available, not required)

Output:
  A JSON inventory file suitable for the AL-to-RHEL migration analyzer.
EOF
    exit 0
}

while getopts "o:h" opt; do
    case "$opt" in
        o) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

log() { echo "[discover] $*" >&2; }
warn() { echo "[discover] WARNING: $*" >&2; }

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# --- OS Detection ---
detect_os() {
    log "Detecting operating system..."
    local name="" version="" id="" arch="" kernel=""

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        name="${NAME:-unknown}"
        version="${VERSION_ID:-unknown}"
        id="${ID:-unknown}"
    elif [[ -f /etc/system-release ]]; then
        name=$(cat /etc/system-release)
        version="unknown"
        id="amzn"
    else
        warn "Cannot detect OS — not Amazon Linux?"
        name="unknown"
        version="unknown"
        id="unknown"
    fi

    arch=$(uname -m 2>/dev/null || echo "unknown")
    kernel=$(uname -r 2>/dev/null || echo "unknown")

    local al_version="unknown"
    if [[ "$id" == "amzn" ]]; then
        case "$version" in
            2)     al_version="al2" ;;
            2023)  al_version="al2023" ;;
            *)     al_version="al-${version}" ;;
        esac
    fi

    cat <<EOF
  "os": {
    "name": "$(json_escape "$name")",
    "version": "$(json_escape "$version")",
    "id": "$(json_escape "$id")",
    "al_version": "$(json_escape "$al_version")",
    "arch": "$(json_escape "$arch")",
    "kernel": "$(json_escape "$kernel")",
    "hostname": "$(json_escape "$HOSTNAME")"
  }
EOF
}

# --- Installed Packages ---
collect_packages() {
    log "Collecting installed packages..."
    if ! command -v rpm &>/dev/null; then
        warn "rpm not found — skipping package collection"
        echo '  "packages": []'
        return
    fi

    local first=true
    echo '  "packages": ['

    rpm -qa --queryformat '%{NAME}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{VENDOR}\t%{INSTALLTIME}\n' 2>/dev/null | \
    sort | while IFS=$'\t' read -r name version release arch vendor installtime; do
        if $first; then
            first=false
        else
            echo ","
        fi
        printf '    {"name": "%s", "version": "%s", "release": "%s", "arch": "%s", "vendor": "%s"}' \
            "$(json_escape "$name")" \
            "$(json_escape "$version")" \
            "$(json_escape "$release")" \
            "$(json_escape "$arch")" \
            "$(json_escape "${vendor:-unknown}")"
    done

    echo ''
    echo '  ]'
}

# --- Repositories ---
collect_repos() {
    log "Collecting repository information..."
    local pkg_mgr=""
    if command -v dnf &>/dev/null; then
        pkg_mgr="dnf"
    elif command -v yum &>/dev/null; then
        pkg_mgr="yum"
    else
        warn "Neither dnf nor yum found — skipping repo collection"
        echo '  "repositories": []'
        return
    fi

    local first=true
    echo '  "repositories": ['

    $pkg_mgr repolist --enabled 2>/dev/null | tail -n +2 | while read -r line; do
        local repo_id
        repo_id=$(echo "$line" | awk '{print $1}')
        [[ -z "$repo_id" || "$repo_id" == "repo" ]] && continue
        if $first; then
            first=false
        else
            echo ","
        fi
        printf '    {"id": "%s", "name": "%s"}' \
            "$(json_escape "$repo_id")" \
            "$(json_escape "$line")"
    done

    echo ''
    echo '  ]'
}

# --- Services ---
collect_services() {
    log "Collecting service information..."
    if ! command -v systemctl &>/dev/null; then
        warn "systemctl not found — skipping service collection"
        echo '  "services_running": [],'
        echo '  "services_enabled": []'
        return
    fi

    local first=true
    echo '  "services_running": ['
    systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | \
    while read -r unit loaded active sub rest; do
        [[ -z "$unit" ]] && continue
        local svc_name="${unit%.service}"
        if $first; then
            first=false
        else
            echo ","
        fi
        printf '    {"name": "%s", "state": "running"}' "$(json_escape "$svc_name")"
    done
    echo ''
    echo '  ],'

    first=true
    echo '  "services_enabled": ['
    systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend 2>/dev/null | \
    while read -r unit state rest; do
        [[ -z "$unit" ]] && continue
        local svc_name="${unit%.service}"
        if $first; then
            first=false
        else
            echo ","
        fi
        printf '    {"name": "%s", "state": "enabled"}' "$(json_escape "$svc_name")"
    done
    echo ''
    echo '  ]'
}

# --- Runtime: Java ---
collect_java() {
    log "Checking Java runtimes..."
    echo '    "java": ['

    local first=true
    local found_java=false

    # Check java command
    if command -v java &>/dev/null; then
        found_java=true
        local java_version
        java_version=$(java -version 2>&1 | head -1 | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")
        local java_home
        java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)" 2>/dev/null || echo "")")" 2>/dev/null || echo "unknown")
        printf '      {"version": "%s", "home": "%s", "source": "PATH"}' \
            "$(json_escape "$java_version")" \
            "$(json_escape "$java_home")"
        first=false
    fi

    # Check alternatives
    if command -v alternatives &>/dev/null; then
        alternatives --display java 2>/dev/null | grep '^/' | while read -r alt_path rest; do
            local alt_version
            alt_version=$("$alt_path" -version 2>&1 | head -1 | sed 's/.*"\(.*\)".*/\1/' 2>/dev/null || echo "unknown")
            if $first; then
                first=false
            else
                echo ","
            fi
            printf '      {"version": "%s", "home": "%s", "source": "alternatives"}' \
                "$(json_escape "$alt_version")" \
                "$(json_escape "$alt_path")"
        done
    fi

    # Scan well-known JDK directories
    for jdk_dir in /usr/lib/jvm/* /usr/java/*; do
        [[ -d "$jdk_dir" && -x "${jdk_dir}/bin/java" ]] || continue
        local jdk_version
        jdk_version=$("${jdk_dir}/bin/java" -version 2>&1 | head -1 | sed 's/.*"\(.*\)".*/\1/' 2>/dev/null || echo "unknown")
        if $first; then
            first=false
        else
            echo ","
        fi
        printf '      {"version": "%s", "home": "%s", "source": "filesystem"}' \
            "$(json_escape "$jdk_version")" \
            "$(json_escape "$jdk_dir")"
    done

    echo ''
    echo '    ]'
}

# --- Runtime: Python ---
collect_python() {
    log "Checking Python runtimes..."
    echo '    "python": ['

    local first=true

    for py_cmd in python python2 python3 python3.6 python3.7 python3.8 python3.9 python3.10 python3.11 python3.12; do
        if command -v "$py_cmd" &>/dev/null; then
            local py_version
            py_version=$($py_cmd --version 2>&1 | awk '{print $2}' || echo "unknown")
            local py_path
            py_path=$(command -v "$py_cmd")
            if $first; then
                first=false
            else
                echo ","
            fi
            printf '      {"command": "%s", "version": "%s", "path": "%s"}' \
                "$(json_escape "$py_cmd")" \
                "$(json_escape "$py_version")" \
                "$(json_escape "$py_path")"
        fi
    done

    echo ''
    echo '    ],'

    # Pip packages
    echo '    "python_pip_packages": ['
    first=true
    for pip_cmd in pip pip3; do
        if command -v "$pip_cmd" &>/dev/null; then
            $pip_cmd list --format=columns 2>/dev/null | tail -n +3 | while read -r pkg ver rest; do
                [[ -z "$pkg" ]] && continue
                if $first; then
                    first=false
                else
                    echo ","
                fi
                printf '      {"name": "%s", "version": "%s"}' \
                    "$(json_escape "$pkg")" \
                    "$(json_escape "$ver")"
            done
            break
        fi
    done
    echo ''
    echo '    ]'
}

# --- Runtime: Node.js ---
collect_nodejs() {
    log "Checking Node.js runtimes..."
    echo '    "nodejs": ['

    if command -v node &>/dev/null; then
        local node_version
        node_version=$(node --version 2>/dev/null || echo "unknown")
        local node_path
        node_path=$(command -v node)
        printf '      {"version": "%s", "path": "%s"}' \
            "$(json_escape "$node_version")" \
            "$(json_escape "$node_path")"
    fi

    echo ''
    echo '    ],'

    echo '    "nodejs_global_packages": ['
    local first=true
    if command -v npm &>/dev/null; then
        npm list -g --depth=0 --parseable 2>/dev/null | tail -n +2 | while read -r pkg_path; do
            local pkg_name
            pkg_name=$(basename "$pkg_path")
            [[ -z "$pkg_name" ]] && continue
            if $first; then
                first=false
            else
                echo ","
            fi
            printf '      {"name": "%s"}' "$(json_escape "$pkg_name")"
        done
    fi
    echo ''
    echo '    ]'
}

# --- Runtime: Ruby ---
collect_ruby() {
    log "Checking Ruby runtimes..."
    echo '    "ruby": ['
    if command -v ruby &>/dev/null; then
        local ruby_version
        ruby_version=$(ruby --version 2>/dev/null | awk '{print $2}' || echo "unknown")
        printf '      {"version": "%s", "path": "%s"}' \
            "$(json_escape "$ruby_version")" \
            "$(json_escape "$(command -v ruby)")"
    fi
    echo ''
    echo '    ],'

    echo '    "ruby_gems": ['
    local first=true
    if command -v gem &>/dev/null; then
        gem list --no-versions 2>/dev/null | while read -r gem_name; do
            [[ -z "$gem_name" || "$gem_name" == "*** "* ]] && continue
            if $first; then
                first=false
            else
                echo ","
            fi
            printf '      {"name": "%s"}' "$(json_escape "$gem_name")"
        done
    fi
    echo ''
    echo '    ]'
}

# --- Runtime: Go ---
collect_go() {
    log "Checking Go runtimes..."
    echo '    "go": ['
    if command -v go &>/dev/null; then
        local go_version
        go_version=$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || echo "unknown")
        printf '      {"version": "%s", "path": "%s"}' \
            "$(json_escape "$go_version")" \
            "$(json_escape "$(command -v go)")"
    fi
    echo ''
    echo '    ]'
}

# --- Runtime: PHP ---
collect_php() {
    log "Checking PHP runtimes..."
    echo '    "php": ['
    if command -v php &>/dev/null; then
        local php_version
        php_version=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown")
        printf '      {"version": "%s", "path": "%s"}' \
            "$(json_escape "$php_version")" \
            "$(json_escape "$(command -v php)")"
    fi
    echo ''
    echo '    ],'

    echo '    "php_modules": ['
    local first=true
    if command -v php &>/dev/null; then
        php -m 2>/dev/null | grep -v '^\[' | while read -r mod; do
            [[ -z "$mod" ]] && continue
            if $first; then
                first=false
            else
                echo ","
            fi
            printf '      {"name": "%s"}' "$(json_escape "$mod")"
        done
    fi
    echo ''
    echo '    ]'
}

# --- Runtime: .NET ---
collect_dotnet() {
    log "Checking .NET runtimes..."
    echo '    "dotnet": ['
    local first=true

    if command -v dotnet &>/dev/null; then
        dotnet --list-runtimes 2>/dev/null | while read -r name version path; do
            if $first; then
                first=false
            else
                echo ","
            fi
            printf '      {"name": "%s", "version": "%s"}' \
                "$(json_escape "$name")" \
                "$(json_escape "$version")"
        done
    fi

    echo ''
    echo '    ],'

    echo '    "dotnet_sdks": ['
    first=true
    if command -v dotnet &>/dev/null; then
        dotnet --list-sdks 2>/dev/null | while read -r version path; do
            if $first; then
                first=false
            else
                echo ","
            fi
            printf '      {"version": "%s"}' "$(json_escape "$version")"
        done
    fi
    echo ''
    echo '    ]'
}

# --- Runtime: Perl ---
collect_perl() {
    log "Checking Perl runtimes..."
    echo '    "perl": ['
    if command -v perl &>/dev/null; then
        local perl_version
        perl_version=$(perl -e 'print $^V' 2>/dev/null | sed 's/^v//' || echo "unknown")
        printf '      {"version": "%s", "path": "%s"}' \
            "$(json_escape "$perl_version")" \
            "$(json_escape "$(command -v perl)")"
    fi
    echo ''
    echo '    ]'
}

# --- Kernel Modules ---
collect_kernel_modules() {
    log "Collecting kernel modules..."
    echo '  "kernel_modules": ['
    local first=true

    if command -v lsmod &>/dev/null; then
        lsmod 2>/dev/null | tail -n +2 | while read -r name size used_by rest; do
            [[ -z "$name" ]] && continue
            if $first; then
                first=false
            else
                echo ","
            fi
            printf '    {"name": "%s", "size": "%s"}' \
                "$(json_escape "$name")" \
                "$(json_escape "$size")"
        done
    fi

    echo ''
    echo '  ]'
}

# --- Network Listeners ---
collect_network() {
    log "Collecting network listeners..."
    echo '  "network_listeners": ['
    local first=true

    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | tail -n +2 | while read -r state recv_q send_q local_addr peer_addr process; do
            [[ -z "$local_addr" ]] && continue
            local addr port proc_name
            addr="${local_addr%:*}"
            port="${local_addr##*:}"
            proc_name=$(echo "$process" | grep -oP 'users:\(\("\K[^"]+' 2>/dev/null || echo "unknown")
            if $first; then
                first=false
            else
                echo ","
            fi
            printf '    {"address": "%s", "port": "%s", "process": "%s"}' \
                "$(json_escape "$addr")" \
                "$(json_escape "$port")" \
                "$(json_escape "$proc_name")"
        done
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | tail -n +3 | while read -r proto recv_q send_q local_addr foreign_addr state pid_prog; do
            [[ -z "$local_addr" ]] && continue
            local addr port
            addr="${local_addr%:*}"
            port="${local_addr##*:}"
            if $first; then
                first=false
            else
                echo ","
            fi
            printf '    {"address": "%s", "port": "%s", "process": "%s"}' \
                "$(json_escape "$addr")" \
                "$(json_escape "$port")" \
                "$(json_escape "${pid_prog:-unknown}")"
        done
    else
        warn "Neither ss nor netstat found — skipping network listener collection"
    fi

    echo ''
    echo '  ]'
}

# --- Main ---
main() {
    log "Amazon Linux Discovery Script v${SCRIPT_VERSION}"
    log "Output: ${OUTPUT_FILE}"
    echo ""

    # Validate we're on Amazon Linux (warn but don't fail)
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        if [[ "${ID:-}" != "amzn" ]]; then
            warn "This does not appear to be Amazon Linux (detected: ${ID:-unknown})"
            warn "Proceeding anyway — results may be incomplete"
        fi
    fi

    {
        echo "{"
        echo "  \"schema_version\": \"1.0\","
        echo "  \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"script_version\": \"${SCRIPT_VERSION}\","

        detect_os
        echo ","

        collect_packages
        echo ","

        collect_repos
        echo ","

        collect_services
        echo ","

        echo '  "runtimes": {'
        collect_java
        echo ","
        collect_python
        echo ","
        collect_nodejs
        echo ","
        collect_ruby
        echo ","
        collect_go
        echo ","
        collect_php
        echo ","
        collect_dotnet
        echo ","
        collect_perl
        echo '  },'

        collect_kernel_modules
        echo ","

        collect_network

        echo "}"
    } > "$OUTPUT_FILE"

    log ""
    log "Discovery complete!"
    log "Inventory written to: ${OUTPUT_FILE}"
    log ""
    log "Next steps:"
    log "  1. Transfer this file to your migration analysis workstation"
    log "  2. Upload it to the AL-to-RHEL Migration Analyzer web UI"
    log "     or use the API: curl -X POST -F 'file=@${OUTPUT_FILE}' http://localhost:8000/api/analyze"
}

main "$@"

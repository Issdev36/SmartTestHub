#!/bin/bash
set -euo pipefail  # Enhanced error handling

# SmartTestHub Non-EVM Container Improvements Patch
# Implements security, error handling, performance, and monitoring enhancements

# Color codes for better logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Enhanced logging function
log_enhanced() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "ERROR")   echo -e "${RED}[$timestamp] ❌ ERROR: $message${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[$timestamp] ✅ SUCCESS: $message${NC}" ;;
        "WARNING") echo -e "${YELLOW}[$timestamp] ⚠️  WARNING: $message${NC}" ;;
        "INFO")    echo -e "${BLUE}[$timestamp] ℹ️  INFO: $message${NC}" ;;
        *)         echo "[$timestamp] $message" ;;
    esac
}

# Error handling and cleanup
handle_error() {
    local exit_code=$?
    local line_number=$1
    log_enhanced "ERROR" "Script failed at line $line_number with exit code $exit_code"
    cleanup_on_error
    log_enhanced "WARNING" "Attempting to continue with degraded functionality"
}
cleanup_on_error() {
    log_enhanced "INFO" "Performing cleanup operations"
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -f /tmp/patch_* /tmp/enhanced_fallback /tmp/health_check.sh 2>/dev/null || true
}

trap 'handle_error $LINENO' ERR

log_enhanced "INFO" "Starting SmartTestHub Non-EVM improvements patch"

# ========================================
# SECURITY IMPROVEMENTS
# ========================================

validate_contract_file() {
    local file="$1"
    local extension="${file##*.}"
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        log_enhanced "ERROR" "File $file does not exist or is not readable"
        return 1
    fi
    local file_size
    file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
    local max_size=$((10 * 1024 * 1024))
    if [[ $file_size -gt $max_size ]]; then
        log_enhanced "ERROR" "File $file is too large (${file_size} bytes, max: ${max_size})"
        return 1
    fi
    case $extension in
        rs)
            if ! rustc --parse-only "$file" 2>/dev/null; then
                log_enhanced "ERROR" "Invalid Rust syntax in $file"
                return 1
            fi
            log_enhanced "SUCCESS" "Rust file $file passed validation"
            ;;
        *)
            log_enhanced "WARNING" "Unknown file extension: .$extension"
            ;;
    esac
    return 0
}

sanitize_env_vars() {
    log_enhanced "INFO" "Sanitizing environment variables"
    unset LD_PRELOAD LD_LIBRARY_PATH 2>/dev/null || true
    local required_vars=("HOME" "PATH" "USER")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_enhanced "WARNING" "Required environment variable $var is not set"
        fi
    done
}

check_for_secrets() {
    local file="$1"
    local patterns=("private.*key" "secret" "password" "token" "api.*key")
    for p in "${patterns[@]}"; do
        if grep -qi "$p" "$file" 2>/dev/null; then
            log_enhanced "WARNING" "Potential secret found in $file matching pattern: $p"
        fi
    done
}

apply_security_improvements() {
    log_enhanced "INFO" "Applying security improvements to entrypoint.sh"
    sed -i 's/which xray > \/dev\/null 2>&1/command -v xray > \/dev\/null 2>&1/' /app/entrypoint.sh
    sed -i 's/cargo tarpaulin --config-path \/app\/tarpaulin.toml/cargo tarpaulin --config \/app\/tarpaulin.toml/g' /app/entrypoint.sh
}

# ========================================
# ERROR HANDLING & RESILIENCE IMPROVEMENTS
# ========================================

handle_tool_error() {
    local tool="$1" exit_code="$2" file="$3"
    log_enhanced "ERROR" "$tool failed with exit code $exit_code for file $file"
    case $tool in
        "cargo-build") log_enhanced "WARNING" "Build failed, skipping tests for $file" ;;
        "cargo-test")  log_enhanced "WARNING" "Tests failed, continuing analysis" ;;
        "cargo-audit") log_enhanced "WARNING" "Security audit failed, check dependencies manually" ;;
        "tarpaulin")   log_enhanced "WARNING" "Coverage analysis failed, skipping report" ;;
        *)             log_enhanced "WARNING" "Unknown tool error, attempting to continue" ;;
    esac
    return 0
}

retry_with_backoff() {
    local max_attempts="$1"; shift
    local cmd=("$@"); local attempt=1
    while (( attempt<=max_attempts )); do
        if "${cmd[@]}"; then return 0; fi
        log_enhanced "WARNING" "Attempt $attempt failed for: ${cmd[*]}; retrying in $((attempt*2))s"
        sleep $((attempt*2))
        ((attempt++))
    done
    log_enhanced "ERROR" "All $max_attempts attempts failed for: ${cmd[*]}"
    return 1
}

apply_error_handling_improvements() {
    log_enhanced "INFO" "Applying error handling improvements to entrypoint.sh"
    sed -i 's/^set -e$/set -euo pipefail/' /app/entrypoint.sh
    sed -i 's/cargo build-sbf/if ! cargo build; then handle_tool_error "cargo-build" $? "$file"; fi/' /app/entrypoint.sh
    sed -i 's/cargo test/if ! cargo test; then handle_tool_error "cargo-test" $? "$file"; fi/' /app/entrypoint.sh
    sed -i 's/cargo audit/if ! retry_with_backoff 3 cargo audit; then handle_tool_error "cargo-audit" $? "$file"; fi/' /app/entrypoint.sh
    sed -i 's/cargo tarpaulin/if ! cargo tarpaulin --config \/app\/tarpaulin.toml; then handle_tool_error "tarpaulin" $? "$file"; fi/' /app/entrypoint.sh
}

# ========================================
# PERFORMANCE & RESOURCE MANAGEMENT
# ========================================

process_single_contract() {
    local file="$1"
    local filename=$(basename "$file")
    if ! validate_contract_file "$file"; then
        log_enhanced "ERROR" "Validation failed for $filename"
        return 1
    fi
    check_for_secrets "$file"
    log_enhanced "INFO" "Processing $filename"
    # Original processing logic continues here...
}

process_contracts_parallel() {
    local max_jobs=${MAX_PARALLEL_JOBS:-3}
    local job_count=0 pids=()
    log_enhanced "INFO" "Starting parallel processing (max $max_jobs jobs)"
    for file in "$watch_dir"/*.rs; do
        [[ -f $file ]] || continue
        if (( job_count>=max_jobs )); then
            wait -n; ((job_count--))
        fi
        process_single_contract "$file" & pids+=($!); ((job_count++))
        log_enhanced "INFO" "Started $(basename "$file") (PID ${pids[-1]})"
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || log_enhanced "WARNING" "Job $pid failed"
    done
    log_enhanced "SUCCESS" "All parallel jobs completed"
}

monitor_resources() {
    local mem cpu disk
    mem=$(free -m | awk 'NR==2{printf "%.1f%%", $3*100/$2}')
    cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2+$4}')
    disk=$(df /app | awk 'NR==2{print $5}' | sed 's/%//')
    log_enhanced "INFO" "Resources - Memory: $mem, CPU: ${cpu}%, Disk: ${disk}%"
    (( ${mem%\%} > 90 )) && log_enhanced "WARNING" "High memory usage: $mem"
    (( disk > 90 )) && log_enhanced "WARNING" "High disk usage: ${disk}%"
}

apply_performance_improvements() {
    log_enhanced "INFO" "Applying performance improvements"
    sed -i '/^# Main processing loop/i\
process_contracts_parallel\n\
monitor_resources' /app/entrypoint.sh
}

# ========================================
# MONITORING & HEALTH CHECKS
# ========================================

apply_monitoring_improvements() {
    log_enhanced "INFO" "Applying monitoring and health check improvements"
    cat << 'EOF_HEALTH' > /app/health_check.sh
#!/bin/bash
HEALTH_FILE="/tmp/container_health"
if ! pgrep -f "entrypoint.sh" > /dev/null; then
    echo "ERROR: Main entrypoint not running" > "$HEALTH_FILE"; exit 1
fi
if [[ ! -d "$WATCH_DIR" ]]; then
    echo "ERROR: Watch directory inaccessible" > "$HEALTH_FILE"; exit 1
fi
for tool in cargo rustc; do
    command -v "$tool" > /dev/null || { echo "ERROR: $tool missing" > "$HEALTH_FILE"; exit 1; }
done
disk=$(df /app | awk 'NR==2{print $5+0}')
(( disk>95 )) && { echo "ERROR: Disk usage too high: ${disk}%" >"$HEALTH_FILE"; exit 1; }
echo "OK: Container healthy at $(date)" > "$HEALTH_FILE"; exit 0
EOF_HEALTH
    chmod +x /app/health_check.sh

    sed -i '/^# Main processing loop/i\
collect_metrics() { \
    local mfile="/tmp/container_metrics.json"; \
    local ts=$(date +%s); \
    local pf=$(ls -1 /app/processed 2>/dev/null | wc -l); \
    local mu=$(free -m | awk "NR==2{print \$3}"); \
    local cu=$(top -bn1 | grep "Cpu(s)" | awk "{print \$2+\$4}"); \
    local du=$(df /app | awk "NR==2{print \$5+0}"); \
    cat << JSON > "$mfile" \
{ "timestamp": $ts, "container": "non-evm", "metrics": { \
"processed_files": $pf, "memory_usage_mb": $mu, "cpu_usage_percent": $cu, "disk_usage_percent": $du, \
"uptime_seconds": $((ts - START_TIME)) } } \
JSON \
    log_enhanced "INFO" "Metrics collected: $pf files" \
};' /app/entrypoint.sh

    sed -i '/while read path action file; do/a\
    if (( $(date +%s) % 60 == 0 )); then collect_metrics; fi' /app/entrypoint.sh
    sed -i '1a\
START_TIME=$(date +%s)' /app/entrypoint.sh
}

# ========================================
# APPLY ALL IMPROVEMENTS
# ========================================

sanitize_env_vars
apply_security_improvements
apply_error_handling_improvements
apply_performance_improvements
apply_monitoring_improvements

# Additional original fixes
log_enhanced "INFO" "Applying original fixes"
sed -i 's/which xray > \/dev\/null/cmd -v xray > \/dev\/null/' /app/entrypoint.sh
sed -i 's/cargo build-sbf/cargo build/g' /app/entrypoint.sh
sed -i '/🛡️ Running security audit for/a\    cargo generate-lockfile || true' /app/entrypoint.sh

# Enhanced fallback mechanism
log_enhanced "INFO" "Setting up enhanced fallback mechanism"
cat << 'EOF_FALLBACK' > /tmp/enhanced_fallback
setup_directory_watch() {
    local watch_dir="$1" max_retries=3 retry=0
    while (( retry<max_retries )); do
        if inotifywait -m -e close_write,moved_to,create "$watch_dir" 2>/dev/null | \
           while read path action file; do
               [[ "$file" =~ \.rs$ ]] || continue
               if validate_contract_file "$path$file"; then
                   process_single_contract "$path$file"
               else
                   log_enhanced "ERROR" "Validation failed for $file"
               fi
           done; then
            return 0
        fi
        ((retry++))
        log_enhanced "WARNING" "Watch attempt $retry failed; retrying..."
        sleep 5
    done
    log_enhanced "ERROR" "Watch failed; switching to polling"
    while true; do
        for f in "$watch_dir"/*.rs; do
            [[ -f $f ]] || continue
            local mark="/app/processed/$(basename "$f")"
            if [[ ! -f $mark ]]; then
                if process_single_contract "$f"; then
                    mkdir -p /app/processed; touch "$mark"
                fi
            fi
        done
        monitor_resources
        collect_metrics
        sleep 10
    done
}
EOF_FALLBACK

sed -i '/inotifywait/{c\setup_directory_watch "$watch_dir" }' /app/entrypoint.sh
sed -i '/^# Main processing loop/i\'"$(cat /tmp/enhanced_fallback)"'' /app/entrypoint.sh

# Final setup and cleanup
mkdir -p /app/processed /app/logs /app/metrics
chmod +x /app/entrypoint.sh /app/health_check.sh
[[ ! -f /app/Cargo.lock ]] && { log_enhanced "INFO" "Creating Cargo.lock"; touch /app/Cargo.lock; }

# Validate patched entrypoint.sh
if bash -n /app/entrypoint.sh; then
    log_enhanced "SUCCESS" "Entrypoint.sh syntax validation passed"
else
    log_enhanced "ERROR" "Entrypoint.sh has syntax errors!"; exit 1
fi

log_enhanced "SUCCESS" "All comprehensive improvements applied successfully!"
log_enhanced "INFO" "  ✅ Security: Input validation, secret detection, sanitization"
log_enhanced "INFO" "  ✅ Error Handling: Retry mechanisms, graceful degradation"
log_enhanced "INFO" "  ✅ Performance: Parallel processing, resource monitoring"
log_enhanced "INFO" "  ✅ Monitoring: Health checks, metrics collection"
log_enhanced "INFO" "  ✅ Resilience: Enhanced fallback mechanisms"

exit 0
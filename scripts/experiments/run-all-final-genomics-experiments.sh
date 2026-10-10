#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# FINAL FEDERATED GENOMICS EXPERIMENT HARNESS
# ==============================================================================
# Purpose:
#   One-command orchestration for the examiner-requested experiments:
#
#   E1  Network profile verification / manipulation checks
#   E2  Randomised DDIL control-plane campaign (>=30 runs/profile)
#   E3  Stage-decomposition measurements
#   E4  Security attack battery
#   E5  Non-extraction / egress audit
#   E6  Fault injection and recovery
#   E7  Concurrency and control-plane footprint
#   E8  Platform baseline comparison hooks
#   E9  Centralised-transfer comparator
#
# It also records evidence for:
#   H1  Raw-data leakage = 0
#   H2  Authentication/authorisation correctness
#   H3  WAN tolerance of the control path
#   H4  Fault recovery
#   H5  Move-to-data vs centralised transfer
#   H6  Production/platform fidelity
#   H7  Federation scalability (3 -> 4 -> 5 sites)
#
# IMPORTANT LIMITATIONS:
#   - This script does NOT magically implement Rust features that do not exist
#     yet (e.g. RFC 8705 certificate-bound access tokens).
#   - E8 cannot deploy OpenStack/CRANE Cloud without environment-specific
#     credentials/hosts. It runs the same benchmark against endpoints you supply.
#   - E5 can prove blocked API actions and record packet/application evidence,
#     but encrypted packet capture alone cannot classify plaintext payload bytes.
#   - Long partition tests and 100 GB transfer tests are opt-in safety gates.
#
# Run on a-core as root.
# ==============================================================================

# ------------------------------------------------------------------------------
# GENERAL CONFIG
# ------------------------------------------------------------------------------

LAB_ROOT="${LAB_ROOT:-/root/genomics-final-experiment}"
RAW="${LAB_ROOT}/raw"
RESULTS="${LAB_ROOT}/results"
LOGS="${LAB_ROOT}/logs"
PCAPS="${LAB_ROOT}/pcaps"
MANIFEST="${LAB_ROOT}/manifest"
TMP="${LAB_ROOT}/tmp"

mkdir -p "$RAW" "$RESULTS" "$LOGS" "$PCAPS" "$MANIFEST" "$TMP"

MASTER_LOG="${LOGS}/master.log"
FAILED_LOG="${LOGS}/failures.csv"
SKIPPED_LOG="${LOGS}/skipped.csv"

touch "$MASTER_LOG"
[ -f "$FAILED_LOG" ] || echo "timestamp,phase,test,reason" >"$FAILED_LOG"
[ -f "$SKIPPED_LOG" ] || echo "timestamp,phase,test,reason" >"$SKIPPED_LOG"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="${RAW}/${RUN_ID}"
mkdir -p "$RUN_DIR"

RANDOM_SEED="${RANDOM_SEED:-20261007}"
REPETITIONS="${REPETITIONS:-30}"
SECURITY_REPETITIONS="${SECURITY_REPETITIONS:-30}"
EGRESS_REPETITIONS="${EGRESS_REPETITIONS:-100}"
CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1 5 10 25 50}"

# ------------------------------------------------------------------------------
# EXISTING FEDERATION
# ------------------------------------------------------------------------------

SITE_A_MGMT="${SITE_A_MGMT:-137.63.148.73}"
SITE_A_PRIVATE="${SITE_A_PRIVATE:-10.10.10.10}"

SITE_B_MGMT="${SITE_B_MGMT:-137.63.148.42}"
SITE_B_PRIVATE="${SITE_B_PRIVATE:-10.20.20.10}"

SITE_C_MGMT="${SITE_C_MGMT:-137.63.148.104}"
SITE_D_MGMT="${SITE_D_MGMT:-137.63.148.105}"
SITE_E_MGMT="${SITE_E_MGMT:-137.63.148.106}"

ROUTER_A="${ROUTER_A:-137.63.148.179}"
ROUTER_B="${ROUTER_B:-137.63.148.26}"
ROUTER_USER="${ROUTER_USER:-fredrick}"
ROUTER_KEY="${ROUTER_KEY:-/home/fredrick/.ssh/id_rsa}"
ROUTER_WAN_IFACE="${ROUTER_WAN_IFACE:-eth2}"

VM_USER="${VM_USER:-fredrick}"
VM_KEY="${VM_KEY:-/home/fredrick/.ssh/id_rsa}"

# Site B is the full execution reference site.
TARGET_SITE_NAME="${TARGET_SITE_NAME:-site-b}"
TARGET_ENDPOINT="${TARGET_ENDPOINT:-https://${SITE_B_PRIVATE}:8443}"
TARGET_HEALTH="${TARGET_HEALTH:-${TARGET_ENDPOINT}/health}"
TARGET_RAW_EXPORT="${TARGET_RAW_EXPORT:-${TARGET_ENDPOINT}/raw-export}"
TARGET_JOBS="${TARGET_JOBS:-${TARGET_ENDPOINT}/jobs}"

# Keycloak/JWKS
SITE_A_ISSUER="${SITE_A_ISSUER:-https://${SITE_A_PRIVATE}:9443/realms/genomics}"
SITE_B_ISSUER="${SITE_B_ISSUER:-https://${SITE_B_PRIVATE}:9443/realms/genomics}"
SITE_A_JWKS="${SITE_A_JWKS:-${SITE_A_ISSUER}/protocol/openid-connect/certs}"
SITE_B_JWKS="${SITE_B_JWKS:-${SITE_B_ISSUER}/protocol/openid-connect/certs}"

TOKEN_SCRIPT="${TOKEN_SCRIPT:-/home/fredrick/genomics-midterm/scripts/get-token.sh}"

FED_CA_CERT="${FED_CA_CERT:-/etc/federation-tls/ca/ca.crt}"
SITE_A_CERT="${SITE_A_CERT:-/etc/federation-tls/site-a/site-a.crt}"
SITE_A_KEY="${SITE_A_KEY:-/etc/federation-tls/site-a/site-a.key}"

# Optional invalid-token fixtures. If unset, those exact semantic tests are SKIP.
EXPIRED_TOKEN="${EXPIRED_TOKEN:-}"
WRONG_AUD_TOKEN="${WRONG_AUD_TOKEN:-}"
WRONG_ISS_TOKEN="${WRONG_ISS_TOKEN:-}"

# ------------------------------------------------------------------------------
# DDIL PROFILES
# ------------------------------------------------------------------------------
# These values must be justified in the report using measured Ugandan network
# data. The script records both configured treatment and measured treatment.
#
# Format:
#   name|delay_ms|jitter_ms|loss_percent|rate_mbit
# ------------------------------------------------------------------------------

DDIL_PROFILES=(
  "baseline|0|0|0|0"
  "mild|25|5|0.5|50"
  "moderate|50|10|2|20"
  "severe|100|20|5|5"
  "extreme|250|50|10|1"
)

# If YES, delay/loss/rate are applied on router-a WAN egress.
# Verify that the traffic being measured actually traverses this interface.
DDIL_DIRECTION="${DDIL_DIRECTION:-router-a-egress}"

# ------------------------------------------------------------------------------
# E6 SAFETY GATES
# ------------------------------------------------------------------------------

RUN_LONG_PARTITIONS="${RUN_LONG_PARTITIONS:-no}"
PARTITION_SECONDS_SHORT="${PARTITION_SECONDS_SHORT:-60}"
PARTITION_SECONDS_MEDIUM="${PARTITION_SECONDS_MEDIUM:-300}"
PARTITION_SECONDS_LONG="${PARTITION_SECONDS_LONG:-1800}"

# ------------------------------------------------------------------------------
# E8 PLATFORM BASELINE ENDPOINTS
# ------------------------------------------------------------------------------
# Provide HTTPS base URLs when available. Missing values are recorded as SKIP.
# All endpoints should expose the same /health and /raw-export behaviour.
# ------------------------------------------------------------------------------

PLATFORM_SINGLE_NODE_ENDPOINT="${PLATFORM_SINGLE_NODE_ENDPOINT:-$TARGET_ENDPOINT}"
PLATFORM_K3S_ENDPOINT="${PLATFORM_K3S_ENDPOINT:-}"
PLATFORM_OPENSTACK_ENDPOINT="${PLATFORM_OPENSTACK_ENDPOINT:-}"
PLATFORM_CRANE_ENDPOINT="${PLATFORM_CRANE_ENDPOINT:-}"

# ------------------------------------------------------------------------------
# E9 TRANSFER COMPARATOR
# ------------------------------------------------------------------------------
# Preferred: point these to real/public/synthetic data files that are actually
# approximately 1, 10, and 100 GB. If a path is empty or absent, it is SKIPPED.
# ------------------------------------------------------------------------------

DATASET_1GB="${DATASET_1GB:-}"
DATASET_10GB="${DATASET_10GB:-}"
DATASET_100GB="${DATASET_100GB:-}"
CENTRAL_TRANSFER_DEST="${CENTRAL_TRANSFER_DEST:-/tmp/federation-transfer-test}"
RUN_100GB_TRANSFER="${RUN_100GB_TRANSFER:-no}"

# ------------------------------------------------------------------------------
# HYPOTHESES / PRE-REGISTRATION SNAPSHOT
# ------------------------------------------------------------------------------

HYPOTHESES_FILE="${MANIFEST}/hypotheses-${RUN_ID}.txt"

cat >"$HYPOTHESES_FILE" <<EOF
H1 No raw leakage:
  Across the audit campaign, raw sequence bytes released through the federation
  interface should be zero, and protected raw-export requests should be denied.

H2 Authentication correctness:
  Invalid/malformed/tampered/unauthenticated requests should not be accepted.
  Valid requests should not be falsely rejected.

H3 WAN tolerance:
  DDIL treatment must be verified using RTT/loss/throughput measurements.
  Secured control-plane latency and success are measured with >= ${REPETITIONS}
  randomised repetitions per profile.

H4 Fault recovery:
  The system should fail closed and recover after selected service/network faults.
  Recovery time and post-recovery health are measured.

H5 Move-to-data advantage:
  Centralised transfer is compared with the federation control path for configured
  dataset sizes using bytes transferred and elapsed time.

H6 Platform fidelity:
  The same benchmark is executed against configured single-node, k3s, OpenStack
  and CRANE Cloud endpoints. Missing substrates are explicitly marked SKIPPED.

H7 Federation scalability:
  3-, 4- and 5-site secured control-plane tests are compared under the same DDIL
  treatment while policy enforcement remains active.
EOF

# ------------------------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------------------------

ts() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }

log() {
  printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$MASTER_LOG"
}

section() {
  echo | tee -a "$MASTER_LOG"
  echo "==============================================================================" | tee -a "$MASTER_LOG"
  echo "$*" | tee -a "$MASTER_LOG"
  echo "==============================================================================" | tee -a "$MASTER_LOG"
}

fail_record() {
  local phase="$1" test="$2" reason="$3"
  printf '"%s","%s","%s","%s"\n' "$(ts)" "$phase" "$test" "${reason//\"/\"\"}" >>"$FAILED_LOG"
}

skip_record() {
  local phase="$1" test="$2" reason="$3"
  printf '"%s","%s","%s","%s"\n' "$(ts)" "$phase" "$test" "${reason//\"/\"\"}" >>"$SKIPPED_LOG"
}

die() {
  log "ERROR: $*"
  exit 1
}

# ------------------------------------------------------------------------------
# SSH
# ------------------------------------------------------------------------------

vm_ssh() {
  local host="$1"; shift
  ssh -i "$VM_KEY" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "${VM_USER}@${host}" "$@"
}

router_ssh() {
  local host="$1"; shift
  ssh -i "$ROUTER_KEY" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "${ROUTER_USER}@${host}" "$@"
}

# ------------------------------------------------------------------------------
# COMMON HTTP
# ------------------------------------------------------------------------------

get_token() {
  "$TOKEN_SCRIPT"
}

curl_mtls() {
  curl \
    --cacert "$FED_CA_CERT" \
    --cert "$SITE_A_CERT" \
    --key "$SITE_A_KEY" \
    "$@"
}

http_code_mtls() {
  curl_mtls \
    -s \
    -o /dev/null \
    -w '%{http_code}' \
    "$@"
}

# ------------------------------------------------------------------------------
# PREFLIGHT
# ------------------------------------------------------------------------------

preflight() {
  section "PREFLIGHT"

  [ "$(id -u)" -eq 0 ] || die "Run as root."
  [ "$(hostname)" = "a-core" ] || die "Run on a-core."

  for cmd in \
    ssh curl jq awk sed grep ping python3 openssl sha256sum tcpdump timeout \
    iperf3 systemctl tc
  do
    command -v "$cmd" >/dev/null || die "Missing command: $cmd"
  done

  [ -x "$TOKEN_SCRIPT" ] || die "Token helper missing: $TOKEN_SCRIPT"
  [ -r "$FED_CA_CERT" ] || die "Missing CA cert: $FED_CA_CERT"
  [ -r "$SITE_A_CERT" ] || die "Missing client cert: $SITE_A_CERT"
  [ -r "$SITE_A_KEY" ] || die "Missing client key: $SITE_A_KEY"

  vm_ssh "$SITE_B_MGMT" hostname >/dev/null || die "Cannot SSH to Site B."
  router_ssh "$ROUTER_A" 'sudo -n true' >/dev/null || die "Router A sudo/SSH failed."
  router_ssh "$ROUTER_B" 'sudo -n true' >/dev/null || die "Router B sudo/SSH failed."

  router_ssh "$ROUTER_A" \
    'test "$(sysctl -n net.ipv4.ip_forward)" = "1"' \
    || die "Router A forwarding disabled."

  router_ssh "$ROUTER_B" \
    'test "$(sysctl -n net.ipv4.ip_forward)" = "1"' \
    || die "Router B forwarding disabled."

  for ip in "$SITE_C_MGMT" "$SITE_D_MGMT" "$SITE_E_MGMT"; do
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      log "Additional federation endpoint reachable: $ip"
    else
      log "WARNING: additional site $ip not reachable; 3/4/5-site phase may skip it."
    fi
  done

  local token
  token="$(get_token)"
  [ -n "$token" ] || die "Could not obtain JWT."

  local code
  code="$(
    curl_mtls \
      -s \
      -o /dev/null \
      -w '%{http_code}' \
      -H "Authorization: Bearer ${token}" \
      "$TARGET_RAW_EXPORT" \
      || true
  )"

  log "Authenticated raw-export preflight HTTP code: $code"

  save_environment_manifest
}

save_environment_manifest() {
  section "RECORDING ENVIRONMENT"

  {
    echo "run_id=$RUN_ID"
    echo "date_utc=$(date -u --iso-8601=seconds)"
    echo "hostname=$(hostname)"
    echo "kernel=$(uname -a)"
    echo "random_seed=$RANDOM_SEED"
    echo "repetitions=$REPETITIONS"
    echo
    echo "[local software]"
    rustc --version 2>/dev/null || true
    cargo --version 2>/dev/null || true
    nginx -v 2>&1 || true
    iperf3 --version 2>&1 | head -n 1 || true
    tc -V 2>&1 || true
    python3 --version
    echo
    echo "[site-b]"
    vm_ssh "$SITE_B_MGMT" \
      'hostname; uname -a; nproc; free -h; df -h /; \
       command -v nextflow >/dev/null && nextflow -version 2>&1 | head -n 5 || true; \
       command -v srun >/dev/null && srun --version || true; \
       nginx -v 2>&1 || true'
  } >"${MANIFEST}/environment-${RUN_ID}.txt"

  sha256sum "$HYPOTHESES_FILE" >"${MANIFEST}/hypotheses-${RUN_ID}.sha256"
}

# ------------------------------------------------------------------------------
# DDIL CONTROL
# ------------------------------------------------------------------------------

profile_field() {
  local row="$1" idx="$2"
  echo "$row" | awk -F'|' -v i="$idx" '{print $i}'
}

apply_ddil() {
  local row="$1"
  local name delay jitter loss rate

  name="$(profile_field "$row" 1)"
  delay="$(profile_field "$row" 2)"
  jitter="$(profile_field "$row" 3)"
  loss="$(profile_field "$row" 4)"
  rate="$(profile_field "$row" 5)"

  log "Applying DDIL profile=$name delay=${delay}ms jitter=${jitter}ms loss=${loss}% rate=${rate}Mbit"

  router_ssh "$ROUTER_A" "
    sudo tc qdisc del dev ${ROUTER_WAN_IFACE} root 2>/dev/null || true

    if [ '${name}' = 'baseline' ]; then
      sudo tc qdisc replace dev ${ROUTER_WAN_IFACE} root fq_codel
    else
      sudo tc qdisc replace dev ${ROUTER_WAN_IFACE} root handle 1: netem \
        delay ${delay}ms ${jitter}ms \
        loss ${loss}% \
        rate ${rate}mbit
    fi

    tc qdisc show dev ${ROUTER_WAN_IFACE}
  " | tee "${LOGS}/qdisc-${name}-${RUN_ID}.txt"
}

reset_ddil() {
  router_ssh "$ROUTER_A" "
    sudo tc qdisc del dev ${ROUTER_WAN_IFACE} root 2>/dev/null || true
    sudo tc qdisc replace dev ${ROUTER_WAN_IFACE} root fq_codel
    tc qdisc show dev ${ROUTER_WAN_IFACE}
  " >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# E1 - MANIPULATION CHECK
# ------------------------------------------------------------------------------

ensure_iperf_server() {
  vm_ssh "$SITE_B_MGMT" "
    pkill -f 'iperf3 -s' 2>/dev/null || true
    nohup iperf3 -s -D >/tmp/iperf3-server.log 2>&1 || true
  "
}

measure_network_profile() {
  local row="$1"
  local name delay jitter loss rate out
  name="$(profile_field "$row" 1)"
  delay="$(profile_field "$row" 2)"
  jitter="$(profile_field "$row" 3)"
  loss="$(profile_field "$row" 4)"
  rate="$(profile_field "$row" 5)"

  out="${RUN_DIR}/e1-${name}.csv"

  echo "profile,configured_delay_ms,configured_jitter_ms,configured_loss_percent,configured_rate_mbit,measured_rtt_avg_ms,measured_loss_percent,measured_throughput_mbps" >"$out"

  apply_ddil "$row"
  sleep 2

  local ping_out rtt loss_meas iperf_out throughput

  ping_out="$(
    ping -c 20 -W 3 "$SITE_B_PRIVATE" 2>&1 || true
  )"

  echo "$ping_out" >"${LOGS}/e1-ping-${name}-${RUN_ID}.txt"

  rtt="$(
    echo "$ping_out" \
      | awk -F'=' '/rtt min\/avg\/max/ {gsub(/ /,"",$2); split($2,a,"/"); print a[2]}'
  )"
  [ -n "$rtt" ] || rtt="NA"

  loss_meas="$(
    echo "$ping_out" \
      | awk -F',' '/packet loss/ {gsub(/% packet loss/,"",$3); gsub(/ /,"",$3); print $3}'
  )"
  [ -n "$loss_meas" ] || loss_meas="NA"

  iperf_out="$(
    iperf3 -c "$SITE_B_PRIVATE" -t 10 -J 2>&1 || true
  )"

  echo "$iperf_out" >"${LOGS}/e1-iperf-${name}-${RUN_ID}.json"

  throughput="$(
    echo "$iperf_out" \
      | jq -r '.end.sum_received.bits_per_second / 1000000' 2>/dev/null \
      || true
  )"
  [ -n "$throughput" ] && [ "$throughput" != "null" ] || throughput="NA"

  echo "${name},${delay},${jitter},${loss},${rate},${rtt},${loss_meas},${throughput}" >>"$out"

  reset_ddil
}

run_e1() {
  section "E1 - NETWORK PROFILE VERIFICATION"

  ensure_iperf_server

  local aggregate="${RESULTS}/e1-network-verification-${RUN_ID}.csv"
  echo "profile,configured_delay_ms,configured_jitter_ms,configured_loss_percent,configured_rate_mbit,measured_rtt_avg_ms,measured_loss_percent,measured_throughput_mbps" >"$aggregate"

  for row in "${DDIL_PROFILES[@]}"; do
    measure_network_profile "$row"
    tail -n 1 "${RUN_DIR}/e1-$(profile_field "$row" 1).csv" >>"$aggregate"
  done

  log "E1 results: $aggregate"
}

# ------------------------------------------------------------------------------
# E2/E3 - RANDOMISED DDIL CONTROL-PLANE CAMPAIGN + STAGE TIMING
# ------------------------------------------------------------------------------

build_randomised_schedule() {
  local schedule="$TMP/schedule-${RUN_ID}.txt"

  python3 - "$RANDOM_SEED" "$REPETITIONS" "$schedule" <<'PY'
import random, sys
seed=int(sys.argv[1]); reps=int(sys.argv[2]); out=sys.argv[3]
profiles=["baseline","mild","moderate","severe","extreme"]
random.seed(seed)
rows=[]
for block in range(1,reps+1):
    p=profiles[:]
    random.shuffle(p)
    for profile in p:
        rows.append((block,profile))
with open(out,"w") as f:
    for block,profile in rows:
        f.write(f"{block},{profile}\n")
PY

  echo "$schedule"
}

profile_row_by_name() {
  local wanted="$1"
  local row
  for row in "${DDIL_PROFILES[@]}"; do
    if [ "$(profile_field "$row" 1)" = "$wanted" ]; then
      echo "$row"
      return 0
    fi
  done
  return 1
}

measure_stage_row() {
  local federation_size="$1"
  local target_name="$2"
  local target_base="$3"
  local block="$4"
  local profile="$5"
  local output="$6"

  local token_start token_end token_ms token
  token_start="$(date +%s%N)"
  token="$(get_token)"
  token_end="$(date +%s%N)"
  token_ms="$(( (token_end-token_start)/1000000 ))"

  local jwks_a jwks_b opa_ms
  jwks_a="$(
    curl -sS -o /dev/null \
      --cacert "$FED_CA_CERT" \
      -w '%{time_total}' \
      "$SITE_A_JWKS" 2>/dev/null \
      || echo NA
  )"

  jwks_b="$(
    curl -sS -o /dev/null \
      --cacert "$FED_CA_CERT" \
      -w '%{time_total}' \
      "$SITE_B_JWKS" 2>/dev/null \
      || echo NA
  )"

  # Direct OPA timing on Site B (local decision service)
  opa_ms="$(
    vm_ssh "$SITE_B_MGMT" \
      "curl -s -o /dev/null -w '%{time_total}' \
       -X POST -H 'Content-Type: application/json' \
       -d '{\"input\":{\"action\":\"raw_export\",\"role\":\"researcher\"}}' \
       http://127.0.0.1:8181/v1/data/genomics/authz/allow" \
      2>/dev/null \
      || echo NA
  )"

  local curl_metrics
  curl_metrics="$(
    curl_mtls \
      -s \
      -o /dev/null \
      -w '%{http_code},%{time_connect},%{time_appconnect},%{time_starttransfer},%{time_total}' \
      -X POST \
      -H "Authorization: Bearer ${token}" \
      "${target_base}/raw-export" \
      || true
  )"

  local code tcp tls ttfb total
  IFS=, read -r code tcp tls ttfb total <<<"$curl_metrics"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$block" "$profile" "$federation_size" "$target_name" \
    "$token_ms" "$jwks_a" "$jwks_b" "$opa_ms" \
    "$tcp" "$tls" "$ttfb" "$total,$code" >>"$output"
}

run_ddil_for_size() {
  local size="$1"
  shift
  local targets=("$@")

  local schedule
  schedule="$(build_randomised_schedule)"

  local out="${RESULTS}/e2-e3-${size}sites-${RUN_ID}.csv"
  echo "block,profile,federation_size,target,token_ms,jwks_a_s,jwks_b_s,opa_s,tcp_connect_s,tls_appconnect_s,ttfb_s,total_s,http_code" >"$out"

  local current_profile=""
  while IFS=, read -r block profile; do
    if [ "$profile" != "$current_profile" ]; then
      local row
      row="$(profile_row_by_name "$profile")"
      apply_ddil "$row"
      sleep 1
      current_profile="$profile"
    fi

    local entry name base
    for entry in "${targets[@]}"; do
      name="${entry%%=*}"
      base="${entry#*=}"

      measure_stage_row \
        "$size" \
        "$name" \
        "$base" \
        "$block" \
        "$profile" \
        "$out"

      log "E2/E3 size=${size} block=${block} profile=${profile} target=${name}"
    done
  done <"$schedule"

  reset_ddil
  log "E2/E3 results: $out"
}

run_e2_e3() {
  section "E2/E3 - RANDOMISED DDIL + STAGE DECOMPOSITION"

  run_ddil_for_size \
    3 \
    "site-b=https://${SITE_B_PRIVATE}:8443" \
    "site-c=https://${SITE_C_MGMT}:8443"

  if ping -c 1 -W 1 "$SITE_D_MGMT" >/dev/null 2>&1; then
    run_ddil_for_size \
      4 \
      "site-b=https://${SITE_B_PRIVATE}:8443" \
      "site-c=https://${SITE_C_MGMT}:8443" \
      "site-d=https://${SITE_D_MGMT}:8443"
  else
    skip_record "E2/E3" "4-site" "Site D unavailable"
  fi

  if ping -c 1 -W 1 "$SITE_E_MGMT" >/dev/null 2>&1; then
    run_ddil_for_size \
      5 \
      "site-b=https://${SITE_B_PRIVATE}:8443" \
      "site-c=https://${SITE_C_MGMT}:8443" \
      "site-d=https://${SITE_D_MGMT}:8443" \
      "site-e=https://${SITE_E_MGMT}:8443"
  else
    skip_record "E2/E3" "5-site" "Site E unavailable"
  fi
}

# ------------------------------------------------------------------------------
# E4 - SECURITY ATTACK BATTERY
# ------------------------------------------------------------------------------

record_security() {
  local out="$1" case_name="$2" expected="$3" observed="$4" detail="$5"

  local verdict="PASS"
  [ "$expected" = "$observed" ] || verdict="FAIL"

  echo "\"${case_name}\",\"${expected}\",\"${observed}\",\"${verdict}\",\"${detail//\"/\"\"}\"" >>"$out"

  if [ "$verdict" = "FAIL" ]; then
    fail_record "E4" "$case_name" "expected=$expected observed=$observed"
  fi
}

tamper_jwt() {
  local token="$1"
  python3 - "$token" <<'PY'
import base64, json, sys
t=sys.argv[1].split(".")
if len(t)!=3:
    print(sys.argv[1]); raise SystemExit
pad=lambda s:s+"="*((4-len(s)%4)%4)
p=json.loads(base64.urlsafe_b64decode(pad(t[1])))
p["role"]="admin"
enc=base64.urlsafe_b64encode(json.dumps(p,separators=(",",":")).encode()).decode().rstrip("=")
print(t[0]+"."+enc+"."+t[2])
PY
}

run_e4() {
  section "E4 - SECURITY ATTACK BATTERY"

  local out="${RESULTS}/e4-security-battery-${RUN_ID}.csv"
  echo '"case","expected_http","observed_http","verdict","detail"' >"$out"

  local valid_token
  valid_token="$(get_token)"

  # No JWT
  local code
  code="$(
    curl_mtls -s -o /dev/null -w '%{http_code}' \
      -X POST "$TARGET_RAW_EXPORT" || true
  )"
  record_security "$out" "missing_jwt" "401" "$code" "mTLS present, Authorization absent"

  # No mTLS
  code="$(
    curl -s -o /dev/null -w '%{http_code}' \
      --cacert "$FED_CA_CERT" \
      -X POST \
      -H "Authorization: Bearer ${valid_token}" \
      "$TARGET_RAW_EXPORT" || true
  )"
  case "$code" in
    400|403) record_security "$out" "missing_mtls" "$code" "$code" "expected TLS/client-cert rejection" ;;
    *) record_security "$out" "missing_mtls" "400_or_403" "$code" "expected TLS/client-cert rejection" ;;
  esac

  # Malformed JWT
  code="$(
    curl_mtls -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer not.a.valid.jwt" \
      "$TARGET_RAW_EXPORT" || true
  )"
  record_security "$out" "malformed_jwt" "401" "$code" "syntactically invalid token"

  # Tampered valid token
  local tampered
  tampered="$(tamper_jwt "$valid_token")"
  code="$(
    curl_mtls -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${tampered}" \
      "$TARGET_RAW_EXPORT" || true
  )"
  record_security "$out" "tampered_signed_token" "401" "$code" "payload changed without resigning"

  # Valid JWT to protected raw export must be denied by policy.
  code="$(
    curl_mtls -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${valid_token}" \
      "$TARGET_RAW_EXPORT" || true
  )"
  record_security "$out" "valid_auth_raw_export" "403" "$code" "OPA policy denial expected"

  # Optional semantic JWT fixtures
  if [ -n "$EXPIRED_TOKEN" ]; then
    code="$(curl_mtls -s -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer ${EXPIRED_TOKEN}" "$TARGET_RAW_EXPORT" || true)"
    record_security "$out" "expired_jwt" "401" "$code" "fixture supplied"
  else
    skip_record "E4" "expired_jwt" "EXPIRED_TOKEN not supplied"
  fi

  if [ -n "$WRONG_AUD_TOKEN" ]; then
    code="$(curl_mtls -s -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer ${WRONG_AUD_TOKEN}" "$TARGET_RAW_EXPORT" || true)"
    record_security "$out" "wrong_audience" "401" "$code" "fixture supplied"
  else
    skip_record "E4" "wrong_audience" "WRONG_AUD_TOKEN not supplied"
  fi

  if [ -n "$WRONG_ISS_TOKEN" ]; then
    code="$(curl_mtls -s -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer ${WRONG_ISS_TOKEN}" "$TARGET_RAW_EXPORT" || true)"
    record_security "$out" "wrong_issuer" "401" "$code" "fixture supplied"
  else
    skip_record "E4" "wrong_issuer" "WRONG_ISS_TOKEN not supplied"
  fi

  # OPA down should fail closed.
  vm_ssh "$SITE_B_MGMT" 'sudo systemctl stop opa'
  sleep 1
  code="$(
    curl_mtls -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${valid_token}" \
      "$TARGET_RAW_EXPORT" || true
  )"
  vm_ssh "$SITE_B_MGMT" 'sudo systemctl start opa'
  sleep 2

  case "$code" in
    401|403|500|502|503)
      record_security "$out" "opa_unavailable_fail_closed" "$code" "$code" "request not accepted"
      ;;
    2*)
      record_security "$out" "opa_unavailable_fail_closed" "non_2xx" "$code" "FALSE ACCEPT"
      ;;
    *)
      record_security "$out" "opa_unavailable_fail_closed" "$code" "$code" "non-success observed"
      ;;
  esac

  log "E4 results: $out"
}

# ------------------------------------------------------------------------------
# E5 - NON-EXTRACTION / EGRESS AUDIT
# ------------------------------------------------------------------------------

run_e5() {
  section "E5 - NON-EXTRACTION / EGRESS AUDIT"

  local out="${RESULTS}/e5-egress-audit-${RUN_ID}.csv"
  echo "request,expected,http_code,response_bytes,pcap_file" >"$out"

  local pcap="${PCAPS}/site-b-loopback-${RUN_ID}.pcap"
  local remote_pcap="/tmp/site-b-loopback-${RUN_ID}.pcap"

  # Capture plaintext localhost traffic between Nginx and Rust agent.
  vm_ssh "$SITE_B_MGMT" \
    "sudo rm -f '${remote_pcap}'; \
     sudo nohup tcpdump -i lo -s 0 -w '${remote_pcap}' tcp port 8080 \
     >/tmp/e5-tcpdump.log 2>&1 & echo \$! | sudo tee /tmp/e5-tcpdump.pid >/dev/null"

  sleep 2

  local token
  token="$(get_token)"

  for i in $(seq 1 "$EGRESS_REPETITIONS"); do
    local body="${TMP}/e5-body-${i}.bin"
    local code

    code="$(
      curl_mtls \
        -s \
        -o "$body" \
        -w '%{http_code}' \
        -X POST \
        -H "Authorization: Bearer ${token}" \
        "$TARGET_RAW_EXPORT" \
        || true
    )"

    local bytes
    bytes="$(wc -c <"$body")"

    echo "${i},403,${code},${bytes},${remote_pcap}" >>"$out"

    if [ "$code" != "403" ]; then
      fail_record "E5" "raw_export_${i}" "expected 403 got ${code}"
    fi
  done

  vm_ssh "$SITE_B_MGMT" \
    "sudo kill \$(cat /tmp/e5-tcpdump.pid) 2>/dev/null || true; \
     sleep 1; sudo chmod 0644 '${remote_pcap}'"

  scp -i "$VM_KEY" \
      -o BatchMode=yes \
      "${VM_USER}@${SITE_B_MGMT}:${remote_pcap}" \
      "$pcap" \
      >/dev/null 2>&1 \
      || true

  # Record output/work manifests for reviewer inspection.
  vm_ssh "$SITE_B_MGMT" \
    'find /genomics/work -xdev -type f -printf "%p,%s,%TY-%Tm-%TdT%TH:%TM:%TS\n" 2>/dev/null | sort' \
    >"${RESULTS}/e5-site-b-work-manifest-${RUN_ID}.csv" \
    || true

  log "E5 API results: $out"
  log "E5 loopback capture: $pcap"
}

# ------------------------------------------------------------------------------
# E6 - FAULT INJECTION
# ------------------------------------------------------------------------------

measure_health_recovery() {
  local label="$1"
  local start_ns end_ns elapsed_ms

  start_ns="$(date +%s%N)"

  for _ in $(seq 1 120); do
    if curl_mtls -fsS "$TARGET_HEALTH" >/dev/null 2>&1; then
      end_ns="$(date +%s%N)"
      elapsed_ms="$(( (end_ns-start_ns)/1000000 ))"
      echo "${label},${elapsed_ms}" >>"${RESULTS}/e6-recovery-${RUN_ID}.csv"
      return 0
    fi
    sleep 1
  done

  echo "${label},TIMEOUT" >>"${RESULTS}/e6-recovery-${RUN_ID}.csv"
  fail_record "E6" "$label" "health did not recover within 120s"
  return 1
}

partition_site_b_private() {
  local seconds="$1"

  router_ssh "$ROUTER_A" "
    sudo iptables -I FORWARD 1 -d ${SITE_B_PRIVATE}/32 -j DROP
    sudo iptables -I FORWARD 1 -s ${SITE_B_PRIVATE}/32 -j DROP
  "

  log "WAN partition active for ${seconds}s"
  sleep "$seconds"

  router_ssh "$ROUTER_A" "
    sudo iptables -D FORWARD -d ${SITE_B_PRIVATE}/32 -j DROP 2>/dev/null || true
    sudo iptables -D FORWARD -s ${SITE_B_PRIVATE}/32 -j DROP 2>/dev/null || true
  "
}

run_e6() {
  section "E6 - FAULT INJECTION AND RECOVERY"

  echo "fault,recovery_ms" >"${RESULTS}/e6-recovery-${RUN_ID}.csv"

  # Agent restart
  vm_ssh "$SITE_B_MGMT" 'sudo systemctl stop federation-agent'
  sleep 3
  vm_ssh "$SITE_B_MGMT" 'sudo systemctl start federation-agent'
  measure_health_recovery "agent_restart" || true

  # OPA restart: agent should remain fail-closed while unavailable.
  vm_ssh "$SITE_B_MGMT" 'sudo systemctl stop opa'
  sleep 3
  vm_ssh "$SITE_B_MGMT" 'sudo systemctl start opa'
  measure_health_recovery "opa_restart" || true

  # Nginx restart
  vm_ssh "$SITE_B_MGMT" 'sudo systemctl restart nginx'
  measure_health_recovery "nginx_restart" || true

  # Short partition
  partition_site_b_private "$PARTITION_SECONDS_SHORT" &
  local p=$!
  sleep 2
  local token code
  token="$(get_token)"
  code="$(
    timeout 10 \
      curl_mtls -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${token}" \
      "$TARGET_RAW_EXPORT" \
      || true
  )"
  echo "partition_short_during_fault,http_${code}" \
    >>"${RESULTS}/e6-fault-observations-${RUN_ID}.txt"
  wait "$p"
  measure_health_recovery "partition_${PARTITION_SECONDS_SHORT}s" || true

  # Optional medium/long partitions.
  if [ "$RUN_LONG_PARTITIONS" = "yes" ]; then
    for seconds in "$PARTITION_SECONDS_MEDIUM" "$PARTITION_SECONDS_LONG"; do
      partition_site_b_private "$seconds"
      measure_health_recovery "partition_${seconds}s" || true
    done
  else
    skip_record "E6" "long_partitions" "RUN_LONG_PARTITIONS != yes"
  fi

  # Key rotation requires explicit admin automation not available in this lab script.
  skip_record "E6" "key_rotation_during_partition" "Keycloak admin credentials/API procedure not configured"
}

# ------------------------------------------------------------------------------
# E7 - CONCURRENCY / FOOTPRINT
# ------------------------------------------------------------------------------

run_concurrency_level() {
  local level="$1"
  local out="$2"
  local token
  token="$(get_token)"

  local cpu_before mem_before cpu_after mem_after
  cpu_before="$(vm_ssh "$SITE_B_MGMT" "ps -C federation-agent -o %cpu= | awk '{s+=\$1} END{print s+0}'")"
  mem_before="$(vm_ssh "$SITE_B_MGMT" "ps -C federation-agent -o rss= | awk '{s+=\$1} END{print s+0}'")"

  local tmpdir="${TMP}/conc-${level}-${RUN_ID}"
  mkdir -p "$tmpdir"

  for i in $(seq 1 "$level"); do
    (
      curl_mtls \
        -s \
        -o /dev/null \
        -w "${i},%{http_code},%{time_total}\n" \
        -X POST \
        -H "Authorization: Bearer ${token}" \
        "$TARGET_RAW_EXPORT" \
        >"${tmpdir}/${i}.csv" \
        || true
    ) &
  done
  wait

  cpu_after="$(vm_ssh "$SITE_B_MGMT" "ps -C federation-agent -o %cpu= | awk '{s+=\$1} END{print s+0}'")"
  mem_after="$(vm_ssh "$SITE_B_MGMT" "ps -C federation-agent -o rss= | awk '{s+=\$1} END{print s+0}'")"

  cat "$tmpdir"/*.csv >"${tmpdir}/all.csv"

  python3 - "$level" "${tmpdir}/all.csv" "$cpu_before" "$cpu_after" "$mem_before" "$mem_after" >>"$out" <<'PY'
import csv, statistics, sys
level=int(sys.argv[1]); path=sys.argv[2]
cpu_b=float(sys.argv[3]); cpu_a=float(sys.argv[4]); mem_b=float(sys.argv[5]); mem_a=float(sys.argv[6])
rows=[]
with open(path) as f:
    for r in csv.reader(f):
        if len(r)==3:
            rows.append((int(r[1]), float(r[2])))
lat=[x[1] for x in rows]
ok=sum(1 for code,_ in rows if code==403)
print(f"{level},{len(rows)},{ok},{statistics.mean(lat) if lat else 'NA'},{max(lat) if lat else 'NA'},{cpu_b},{cpu_a},{mem_b},{mem_a}")
PY
}

run_e7() {
  section "E7 - CONCURRENCY AND FOOTPRINT"

  local out="${RESULTS}/e7-concurrency-${RUN_ID}.csv"
  echo "concurrency,requests,expected_403_count,mean_latency_s,max_latency_s,cpu_before,cpu_after,rss_kb_before,rss_kb_after" >"$out"

  local level
  for level in $CONCURRENCY_LEVELS; do
    run_concurrency_level "$level" "$out"
    log "E7 concurrency=${level} complete"
  done
}

# ------------------------------------------------------------------------------
# E8 - PLATFORM BASELINES
# ------------------------------------------------------------------------------

benchmark_platform_endpoint() {
  local platform="$1"
  local base="$2"
  local out="$3"

  if [ -z "$base" ]; then
    skip_record "E8" "$platform" "endpoint not configured"
    return 0
  fi

  local token
  token="$(get_token)"

  for i in $(seq 1 "$REPETITIONS"); do
    local result code total
    result="$(
      curl_mtls \
        -s \
        -o /dev/null \
        -w '%{http_code},%{time_total}' \
        -X POST \
        -H "Authorization: Bearer ${token}" \
        "${base}/raw-export" \
        || true
    )"
    code="${result%,*}"
    total="${result#*,}"
    echo "${platform},${i},${code},${total}" >>"$out"
  done
}

run_e8() {
  section "E8 - PLATFORM BASELINE COMPARISON"

  local out="${RESULTS}/e8-platform-baselines-${RUN_ID}.csv"
  echo "platform,run,http_code,total_s" >"$out"

  benchmark_platform_endpoint "single-node-rust" "$PLATFORM_SINGLE_NODE_ENDPOINT" "$out"
  benchmark_platform_endpoint "k3s" "$PLATFORM_K3S_ENDPOINT" "$out"
  benchmark_platform_endpoint "openstack" "$PLATFORM_OPENSTACK_ENDPOINT" "$out"
  benchmark_platform_endpoint "crane-cloud" "$PLATFORM_CRANE_ENDPOINT" "$out"

  log "E8 results: $out"
}

# ------------------------------------------------------------------------------
# E9 - CENTRALISED TRANSFER COMPARATOR
# ------------------------------------------------------------------------------

transfer_dataset() {
  local label="$1"
  local path="$2"
  local out="$3"

  if [ -z "$path" ] || [ ! -f "$path" ]; then
    skip_record "E9" "$label" "dataset path missing"
    return 0
  fi

  if [ "$label" = "100GB" ] && [ "$RUN_100GB_TRANSFER" != "yes" ]; then
    skip_record "E9" "$label" "RUN_100GB_TRANSFER != yes"
    return 0
  fi

  local bytes start end elapsed
  bytes="$(stat -c %s "$path")"

  vm_ssh "$SITE_B_MGMT" "mkdir -p '${CENTRAL_TRANSFER_DEST}'"

  start="$(date +%s%N)"
  rsync -a --info=stats2 \
    -e "ssh -i ${VM_KEY} -o BatchMode=yes" \
    "$path" \
    "${VM_USER}@${SITE_B_MGMT}:${CENTRAL_TRANSFER_DEST}/" \
    >"${LOGS}/e9-rsync-${label}-${RUN_ID}.txt"
  end="$(date +%s%N)"

  elapsed="$(
    awk -v n="$((end-start))" 'BEGIN{printf "%.6f",n/1000000000}'
  )"

  echo "${label},${bytes},${elapsed}" >>"$out"

  vm_ssh "$SITE_B_MGMT" \
    "rm -f '${CENTRAL_TRANSFER_DEST}/$(basename "$path")'"
}

run_e9() {
  section "E9 - CENTRALISED TRANSFER COMPARATOR"

  command -v rsync >/dev/null || {
    skip_record "E9" "all" "rsync missing"
    return 0
  }

  local out="${RESULTS}/e9-central-transfer-${RUN_ID}.csv"
  echo "dataset_label,bytes,transfer_elapsed_s" >"$out"

  transfer_dataset "1GB" "$DATASET_1GB" "$out"
  transfer_dataset "10GB" "$DATASET_10GB" "$out"
  transfer_dataset "100GB" "$DATASET_100GB" "$out"

  # Federation control-plane bytes/time proxy: one authenticated request.
  local token headers body total bytes
  token="$(get_token)"
  headers="${TMP}/e9-fed-headers.txt"
  body="${TMP}/e9-fed-body.bin"

  total="$(
    curl_mtls \
      -s \
      -D "$headers" \
      -o "$body" \
      -w '%{time_total}' \
      -X POST \
      -H "Authorization: Bearer ${token}" \
      "$TARGET_RAW_EXPORT" \
      || true
  )"

  bytes="$(( $(wc -c <"$headers") + $(wc -c <"$body") ))"

  echo "federation_control_request,${bytes},${total}" >>"$out"

  log "E9 results: $out"
}

# ------------------------------------------------------------------------------
# ANALYSIS
# ------------------------------------------------------------------------------

run_analysis() {
  section "ANALYSIS / REPORT TABLES"

  python3 - "$RESULTS" "$RUN_ID" <<'PY'
import csv, glob, math, os, statistics, sys
root=sys.argv[1]; run_id=sys.argv[2]

def q(vals, p):
    vals=sorted(vals)
    if not vals: return None
    if len(vals)==1: return vals[0]
    pos=(len(vals)-1)*p
    lo=math.floor(pos); hi=math.ceil(pos)
    if lo==hi: return vals[lo]
    return vals[lo]+(vals[hi]-vals[lo])*(pos-lo)

# E2/E3 summaries
out=os.path.join(root,f"summary-ddil-{run_id}.csv")
rows=[]
for path in glob.glob(os.path.join(root,f"e2-e3-*sites-{run_id}.csv")):
    with open(path,newline="") as f:
        for r in csv.DictReader(f):
            try:
                rows.append(r)
            except Exception:
                pass

groups={}
for r in rows:
    key=(r["federation_size"],r["target"],r["profile"])
    try:
        total=float(r["total_s"])
    except Exception:
        continue
    groups.setdefault(key,[]).append((total,r["http_code"]))

with open(out,"w",newline="") as f:
    fields=["federation_size","target","profile","n","policy_403_percent","mean_s","median_s","p95_s","max_s","std_s"]
    w=csv.DictWriter(f,fieldnames=fields); w.writeheader()
    for key in sorted(groups):
        vals=[x[0] for x in groups[key]]
        codes=[x[1] for x in groups[key]]
        w.writerow({
            "federation_size":key[0],
            "target":key[1],
            "profile":key[2],
            "n":len(vals),
            "policy_403_percent":round(sum(c=="403" for c in codes)/len(codes)*100,2),
            "mean_s":round(statistics.mean(vals),6),
            "median_s":round(statistics.median(vals),6),
            "p95_s":round(q(vals,.95),6),
            "max_s":round(max(vals),6),
            "std_s":round(statistics.stdev(vals),6) if len(vals)>1 else 0,
        })

# Security summary
sec=glob.glob(os.path.join(root,f"e4-security-battery-{run_id}.csv"))
if sec:
    with open(sec[0],newline="") as f:
        s=list(csv.DictReader(f))
    sout=os.path.join(root,f"summary-security-{run_id}.txt")
    with open(sout,"w") as f:
        f.write(f"cases={len(s)}\n")
        f.write(f"pass={sum(r['verdict']=='PASS' for r in s)}\n")
        f.write(f"fail={sum(r['verdict']=='FAIL' for r in s)}\n")

print(out)
PY

  log "Analysis complete."
}

# ------------------------------------------------------------------------------
# CLEANUP
# ------------------------------------------------------------------------------

cleanup() {
  log "Cleanup: restoring DDIL baseline and critical services."

  reset_ddil || true

  vm_ssh "$SITE_B_MGMT" \
    'sudo systemctl start opa federation-agent nginx >/dev/null 2>&1 || true' \
    >/dev/null 2>&1 || true

  router_ssh "$ROUTER_A" "
    sudo iptables -D FORWARD -d ${SITE_B_PRIVATE}/32 -j DROP 2>/dev/null || true
    sudo iptables -D FORWARD -s ${SITE_B_PRIVATE}/32 -j DROP 2>/dev/null || true
  " >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# CLI
# ------------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage:
  $0 all
  $0 e1
  $0 e2e3
  $0 e4
  $0 e5
  $0 e6
  $0 e7
  $0 e8
  $0 e9
  $0 analysis

Recommended first run:
  $0 e1
  $0 e4
  $0 e2e3
  $0 e5
  $0 e6
  $0 e7
  $0 e8
  $0 e9
  $0 analysis

To run everything:
  $0 all
EOF
}

main() {
  local phase="${1:-all}"

  preflight

  case "$phase" in
    e1)
      run_e1
      ;;
    e2e3)
      run_e2_e3
      ;;
    e4)
      run_e4
      ;;
    e5)
      run_e5
      ;;
    e6)
      run_e6
      ;;
    e7)
      run_e7
      ;;
    e8)
      run_e8
      ;;
    e9)
      run_e9
      ;;
    analysis)
      run_analysis
      ;;
    all)
      run_e1
      run_e2_e3
      run_e4
      run_e5
      run_e6
      run_e7
      run_e8
      run_e9
      run_analysis
      ;;
    *)
      usage
      exit 1
      ;;
  esac

  trap - EXIT INT TERM
  cleanup

  section "EXPERIMENT PHASE COMPLETE"

  echo "Run ID:      $RUN_ID"
  echo "Lab root:    $LAB_ROOT"
  echo "Results:     $RESULTS"
  echo "Raw:         $RUN_DIR"
  echo "Logs:        $LOGS"
  echo "PCAPs:       $PCAPS"
  echo "Hypotheses:  $HYPOTHESES_FILE"
  echo "Failures:    $FAILED_LOG"
  echo "Skipped:     $SKIPPED_LOG"
}

main "$@"

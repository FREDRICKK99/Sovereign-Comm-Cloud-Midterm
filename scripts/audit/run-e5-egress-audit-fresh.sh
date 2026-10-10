#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

KEY="/home/fredrick/.ssh/id_rsa"
REMOTE_USER="fredrick"
BASE="/root/genomics-final-experiment/e5-sovereignty"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$BASE/network/$RUN_ID-${1:-cached}"
CORE="137.63.148.42"
WORKER="137.63.148.140"
STORAGE="137.63.148.102"
API="https://10.20.20.10:8443"
TOKEN_CMD="/home/fredrick/genomics-midterm/scripts/get-token.sh"
CA="/etc/federation-tls/ca/ca.crt"
CERT="/etc/federation-tls/site-a/site-a.crt"
CERT_KEY="/etc/federation-tls/site-a/site-a.key"
MODE="${1:-cached}"
[[ "$MODE" == cached || "$MODE" == fresh ]] || { echo "Usage: $0 [cached|fresh]" >&2; exit 2; }
MAX_WAIT=1200
CAPTURE_LIMIT=1500
ORIGINAL_RESUME=""
RESUME_CHANGED=0
STARTED=0
CLEANED=0
JOB_ID=""
FINAL_STATUS="NOT_SUBMITTED"
mkdir -p "$OUT"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
remote() {
  local host="$1"; shift
  ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 \
    -o ServerAliveCountMax=3 "${REMOTE_USER}@${host}" "$@"
}

# All remote capture operations execute in one privileged shell. No root-owned
# output redirection is performed by the unprivileged SSH login shell.
remote_capture() {
  local host="$1" action="$2" iface="$3"
  remote "$host" "sudo -n bash -s -- '$action' '$RUN_ID' '$iface' '$CAPTURE_LIMIT'" <<'REMOTE'
set -Eeuo pipefail
mode="$1"; run="$2"; iface="$3"; limit="$4"
[[ "$run" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
[[ "$iface" == eth0 || "$iface" == eth1 ]]
dir="/var/tmp/e5-audit/$run"
pidfile="$dir/$iface.pid"
logfile="$dir/$iface.log"
pcap="$dir/$iface.pcap"
case "$mode" in
  start)
    mkdir -p "$dir"
    chmod 700 "$dir"
    [[ ! -e "$pidfile" && ! -e "$pcap" ]] || { echo "Capture files already exist" >&2; exit 1; }
    # The timeout process remains the parent of tcpdump. SIGINT is forwarded
    # to tcpdump so it can flush and close the PCAP gracefully.
    nohup timeout --signal=INT --kill-after=10 "$limit" \
      tcpdump -i "$iface" -n -s 96 -U -w "$pcap" 'ip or ip6' \
      >"$logfile" 2>&1 </dev/null &
    pid=$!
    echo "$pid" >"$pidfile"
    sleep 2
    kill -0 "$pid" 2>/dev/null || { cat "$logfile" >&2; exit 1; }
    [[ -f "$pcap" ]] || { cat "$logfile" >&2; exit 1; }
    printf 'CAPTURE_READY %s pid=%s\n' "$iface" "$pid"
    ;;
  verify)
    [[ -f "$pidfile" && -f "$pcap" ]] || exit 1
    pid=$(cat "$pidfile")
    kill -0 "$pid" 2>/dev/null || { cat "$logfile" >&2; exit 1; }
    [[ $(stat -c %s "$pcap") -ge 24 ]] || exit 1
    printf 'CAPTURE_ACTIVE %s pid=%s\n' "$iface" "$pid"
    ;;
  stop)
    if [[ -f "$pidfile" ]]; then
      pid=$(cat "$pidfile")
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        # Signal tcpdump directly, not unrelated tcpdump processes.
        for child in $(pgrep -P "$pid" || true); do
          if [[ "$(cat "/proc/$child/comm" 2>/dev/null || true)" == tcpdump ]]; then
            kill -INT "$child" 2>/dev/null || true
          fi
        done
        for i in $(seq 1 20); do
          alive=0
          for child in $(pgrep -P "$pid" || true); do
            [[ "$(cat "/proc/$child/comm" 2>/dev/null || true)" == tcpdump ]] && alive=1
          done
          (( alive == 0 )) && break
          sleep 0.25
        done
        kill -TERM "$pid" 2>/dev/null || true
      fi
    fi
    [[ -f "$pcap" ]] || { echo "MISSING_PCAP $iface" >&2; exit 1; }
    printf 'CAPTURE_STOPPED %s bytes=%s\n' "$iface" "$(stat -c %s "$pcap")"
    ;;
  *) exit 2 ;;
esac
REMOTE
}

cleanup() {
  local rc=$?
  trap - EXIT ERR INT TERM
  if (( STARTED == 1 && CLEANED == 0 )); then
    CLEANED=1
    log "Stopping captures and flushing PCAPs"
    for host in "$CORE" "$WORKER" "$STORAGE"; do
      for iface in eth0 eth1; do
        remote_capture "$host" stop "$iface" || log "WARNING: stop failed on $host $iface"
      done
    done
  fi
  if (( RESUME_CHANGED == 1 )); then
    log "Restoring original NEXTFLOW_RESUME=$ORIGINAL_RESUME on Site B"
    if remote "$CORE" "sudo -n sed -i -E 's/^NEXTFLOW_RESUME=.*/NEXTFLOW_RESUME=$ORIGINAL_RESUME/' /etc/federation-agent/site.env && sudo -n systemctl restart federation-agent"; then
      log "Resume setting restored; federation-agent restarted"
      RESUME_CHANGED=0
    else
      log "CRITICAL: Automatic restore failed; restore NEXTFLOW_RESUME=$ORIGINAL_RESUME manually"
      rc=1
    fi
  fi
  if (( rc != 0 )); then log "AUDIT INCOMPLETE (exit=$rc); partial evidence: $OUT"; fi
  return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "E5 audit run: $RUN_ID mode=$MODE"
for cmd in ssh curl jq sha256sum tcpdump; do
  command -v "$cmd" >/dev/null || { log "Missing local command: $cmd"; exit 1; }
done
[[ -r "$KEY" && -r "$CA" && -r "$CERT" && -r "$CERT_KEY" && -x "$TOKEN_CMD" ]] || {
  log "Missing SSH key, TLS credential or token helper"; exit 1;
}
for entry in "$CORE:b-core" "$WORKER:b-worker" "$STORAGE:b-storage"; do
  host=${entry%%:*}; name=${entry#*:}
  log "Preflight: $name"
  remote "$host" 'sudo -n true && command -v tcpdump && ip link show eth0 >/dev/null && ip link show eth1 >/dev/null' >/dev/null
 done
remote "$CORE" 'curl -fsS http://127.0.0.1:8080/health' >"$OUT/health-before.json"
[[ "$(jq -r '.status' "$OUT/health-before.json")" == online ]] || { log 'Agent not online'; exit 1; }
remote "$CORE" 'sinfo -h -o "%N %T"; squeue -h' >"$OUT/slurm-before.txt"
if remote "$CORE" 'squeue -h' | grep -q .; then
  log 'Active Slurm jobs detected; refusing to mix audit with other workloads'; exit 1
fi
if [[ "$MODE" == fresh ]]; then
  ORIGINAL_RESUME=$(remote "$CORE" "sudo -n sed -n 's/^NEXTFLOW_RESUME=//p' /etc/federation-agent/site.env | tail -n 1")
  [[ "$ORIGINAL_RESUME" == true || "$ORIGINAL_RESUME" == false ]] || {
    log 'Cannot determine existing NEXTFLOW_RESUME; refusing to change service'; exit 1;
  }
  printf '%s\n' "$ORIGINAL_RESUME" >"$OUT/nextflow-resume-before.txt"
  node_state=$(remote "$CORE" 'sinfo -h -N -n b-worker -o "%T" | head -n 1')
  [[ "$node_state" == idle ]] || { log "Worker must be idle for fresh run (state=$node_state)"; exit 1; }
  if [[ "$ORIGINAL_RESUME" == true ]]; then
    log 'Temporarily disabling Nextflow resume for fresh Slurm execution'
    # Mark restoration necessary before attempting any change.
    RESUME_CHANGED=1
    remote "$CORE" "sudo -n sed -i -E 's/^NEXTFLOW_RESUME=.*/NEXTFLOW_RESUME=false/' /etc/federation-agent/site.env && sudo -n systemctl restart federation-agent"
    sleep 3
  fi
  [[ "$(remote "$CORE" "sudo -n sed -n 's/^NEXTFLOW_RESUME=//p' /etc/federation-agent/site.env | tail -n 1")" == false ]] || {
    log 'Resume disabling did not take effect'; exit 1;
  }
  remote "$CORE" 'curl -fsS http://127.0.0.1:8080/health' >"$OUT/health-after-mode-change.json"
  [[ "$(jq -r '.status' "$OUT/health-after-mode-change.json")" == online ]] || exit 1
else
  ORIGINAL_RESUME=$(remote "$CORE" "sudo -n sed -n 's/^NEXTFLOW_RESUME=//p' /etc/federation-agent/site.env | tail -n 1")
  printf '%s\n' "$ORIGINAL_RESUME" >"$OUT/nextflow-resume-before.txt"
fi

# Mark cleanup necessary before starting, so partial startup is cleaned up.
STARTED=1
for entry in "$CORE:b-core" "$WORKER:b-worker" "$STORAGE:b-storage"; do
  host=${entry%%:*}; name=${entry#*:}
  for iface in eth0 eth1; do
    log "Starting $name $iface"
    remote_capture "$host" start "$iface"
  done
done
for host in "$CORE" "$WORKER" "$STORAGE"; do
  for iface in eth0 eth1; do remote_capture "$host" verify "$iface"; done
done
log 'All six captures verified; submitting workflow'
TOKEN="$($TOKEN_CMD)"
[[ -n "$TOKEN" ]] || { log 'Token helper returned empty token'; exit 1; }
http=$(curl -sS --connect-timeout 10 --max-time 45 \
  --cacert "$CA" --cert "$CERT" --key "$CERT_KEY" \
  -o "$OUT/job-response.json" -w '%{http_code}' \
  -X POST "$API/jobs" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"dataset_id":"dataset-b-001","workflow":"variant_call"}')
unset TOKEN
[[ "$http" == 202 ]] || { log "Unexpected submit HTTP $http"; exit 1; }
JOB_ID=$(jq -r '.job_id // empty' "$OUT/job-response.json")
[[ "$JOB_ID" =~ ^[a-fA-F0-9-]{36}$ ]] || { log 'Invalid job ID'; exit 1; }
log "Job accepted: $JOB_ID"
printf '%s\n' "$JOB_ID" >"$OUT/job-id.txt"
start_epoch=$(date +%s)
while :; do
  remote "$CORE" "curl -fsS --max-time 10 http://127.0.0.1:8080/jobs/$JOB_ID" >"$OUT/job-status.json"
  FINAL_STATUS=$(jq -r '.status // "UNKNOWN"' "$OUT/job-status.json")
  log "Job status: $FINAL_STATUS"
  case "$FINAL_STATUS" in
    COMPLETED|FAILED|CANCELLED) break ;;
  esac
  if (( $(date +%s) - start_epoch >= MAX_WAIT )); then
    log 'Job polling timed out; captures will be stopped'; break
  fi
  sleep 3
done
# Stop before retrieval and wait for the PCAPs to be closed.
cleanup
STARTED=0
log 'Retrieving PCAPs and capture logs'
for entry in "$CORE:b-core" "$WORKER:b-worker" "$STORAGE:b-storage"; do
  host=${entry%%:*}; name=${entry#*:}
  for iface in eth0 eth1; do
    remote "$host" "sudo -n cat '/var/tmp/e5-audit/$RUN_ID/$iface.pcap'" >"$OUT/$name-$iface.pcap"
    remote "$host" "sudo -n cat '/var/tmp/e5-audit/$RUN_ID/$iface.log'" >"$OUT/$name-$iface.log"
    [[ $(stat -c %s "$OUT/$name-$iface.pcap") -ge 24 ]] || { log "Invalid PCAP $name-$iface"; exit 1; }
    tcpdump -r "$OUT/$name-$iface.pcap" -c 1 >/dev/null 2>&1 || {
      # Header-only PCAP is valid but has no packets; tcpdump returns 0 on most versions.
      log "WARNING: PCAP contains no readable packets: $name-$iface"
    }
  done
done

short=${JOB_ID:0:8}
remote "$CORE" "cat '/genomics/work/federation/logs/$JOB_ID.log'" >"$OUT/nextflow.log" || true
remote "$CORE" "cat '/genomics/work/nextflow-site-b/results/site-b-fed_${short}-trace.txt'" >"$OUT/nextflow-trace.txt" || true

if [[ "$MODE" == fresh ]]; then
  if grep -qE '[[:space:]]CACHED[[:space:]]' "$OUT/nextflow-trace.txt"; then
    log 'ERROR: Fresh mode produced cached Nextflow tasks; results cannot be labelled fresh'
    exit 3
  fi
  if [[ $(grep -cE '[[:space:]]COMPLETED[[:space:]]+0[[:space:]]' "$OUT/nextflow-trace.txt" || true) -ne 4 ]]; then
    log 'ERROR: Fresh mode did not verify four completed task records'
    exit 3
  fi
  log 'Verified four fresh completed Nextflow task records'
fi
# Directional totals count captured IP packet lengths (not genomic data bytes).
printf 'node,interface,packets,ipv4_bytes,ipv6_bytes\n' >"$OUT/traffic-summary.csv"
for pcap in "$OUT"/*.pcap; do
  label=${pcap##*/}; label=${label%.pcap}
  node=${label%-eth?}; iface=${label##*-}
  if command -v tshark >/dev/null; then
    vals=$(tshark -r "$pcap" -T fields -e ip.len -e ipv6.plen 2>/dev/null | \
      awk -F '\t' '{n++; if($1~/^[0-9]+$/)v4+=$1; if($2~/^[0-9]+$/)v6+=$2+40} END{printf "%d,%d,%d",n,v4,v6}')
  else
    vals="$(tcpdump -nn -r "$pcap" 2>/dev/null | wc -l | tr -d ' '),NA,NA"
  fi
  printf '%s,%s,%s\n' "$node" "$iface" "$vals" >>"$OUT/traffic-summary.csv"
done
(
  cd "$OUT"
  sha256sum *.pcap job-response.json job-status.json nextflow.log nextflow-trace.txt >evidence-sha256.txt
)
cat >"$OUT/README.txt" <<EOF
E5 network egress audit
Run ID: $RUN_ID
Mode: $MODE
Original NEXTFLOW_RESUME: $ORIGINAL_RESUME
Job ID: $JOB_ID
Final observed job status: $FINAL_STATUS
Six captures: b-core, b-worker, b-storage x eth0,eth1
Snaplen: 96 bytes (includes limited payload; sensitive evidence)
Capture filter: ip or ip6
Capture timeout: $CAPTURE_LIMIT seconds
Job polling timeout: $MAX_WAIT seconds
Traffic summary: captured IP packet lengths, NOT raw genomic data bytes.
Captures may count internal traffic more than once on different hosts.
TLS content cannot be classified using encrypted PCAP alone.
EOF
log "Completed: status=$FINAL_STATUS evidence=$OUT"
[[ "$FINAL_STATUS" == COMPLETED ]] || exit 2

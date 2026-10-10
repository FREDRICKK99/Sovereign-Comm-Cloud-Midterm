#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# FEDERATED GENOMICS SCALE LAB - CEPH EDITION
# Run on a-core as root.
# ============================================================

# ---- Proxmox / Ceph ----
PVE_HOST="137.63.148.11"
PVE_USER="root"
PVE_SSH_KEY="/root/.ssh/id_ed25519"
TEMPLATE_VMID="9000"
PVE_STORAGE="jmwesi-ceph-rbd"
PVE_BRIDGE="vmbr0"
PVE_VLAN=""

# ---- Existing federation ----
SITE_A_MGMT="137.63.148.73"
SITE_A_PRIVATE="10.10.10.10"
SITE_B_MGMT="137.63.148.42"
SITE_B_PRIVATE="10.20.20.10"
SITE_B_VMID="606"

ROUTER_A="137.63.148.179"
ROUTER_B="137.63.148.26"
ROUTER_USER="fredrick"
ROUTER_SSH_KEY="/home/fredrick/.ssh/id_rsa"

# ---- New endpoint VMs ----
SITE_C_VMID="609"
SITE_D_VMID="610"
SITE_E_VMID="611"

SITE_C_MGMT="137.63.148.104"
SITE_D_MGMT="137.63.148.105"
SITE_E_MGMT="137.63.148.106"

SITE_C_PRIVATE="10.30.30.10"
SITE_D_PRIVATE="10.40.40.10"
SITE_E_PRIVATE="10.50.50.10"

SITE_C_DATASET="dataset-c-001"
SITE_D_DATASET="dataset-d-001"
SITE_E_DATASET="dataset-e-001"

# ---- Cloud-init ----
VM_PREFIX="24"
VM_GATEWAY="137.63.148.1"
VM_DNS="8.8.8.8"
VM_USER="fredrick"
VM_PASSWORD="${VM_PASSWORD:?Set VM_PASSWORD securely in your shell before running}"
VM_SSH_PRIVATE_KEY="/home/fredrick/.ssh/id_rsa"
VM_SSH_PUBLIC_KEY="/home/fredrick/.ssh/id_rsa.pub"

DEFAULT_CORES="4"
DEFAULT_MEMORY="8192"
DISK_SIZE="40G"

# ---- Experiments ----
CONTROL_REPETITIONS="10"
RUN_TWO_SITE_EXPERIMENT="no"
RUN_RESOURCE_EXPERIMENT="yes"

RESOURCE_PROFILES=(
  "small:2:4096"
  "medium:4:8192"
  "large:8:16384"
)

DDIL_PROFILES=(baseline mild moderate severe extreme)

ddil_delay_ms() {
  case "$1" in
    baseline) echo 0 ;;
    mild) echo 25 ;;
    moderate) echo 50 ;;
    severe) echo 100 ;;
    extreme) echo 250 ;;
    *) return 1 ;;
  esac
}

# ---- Deployment files ----
BASE="/root/genomics-scale-experiment"
RESULTS="$BASE/results"
LOGS="$BASE/logs"
DATA="$BASE/data"
CERTS="$BASE/certs"

AGENT_BINARY="/home/fredrick/federation-agent/target/release/federation-agent"
TOKEN_SCRIPT="/home/fredrick/genomics-midterm/scripts/get-token.sh"
OPA_BINARY="/usr/local/bin/opa"
OPA_POLICY="/etc/opa/genomics.rego"

FED_CA_CERT="/etc/federation-tls/ca/ca.crt"
FED_CA_KEY="/etc/federation-tls/ca/ca.key"
SITE_A_CLIENT_CERT="/etc/federation-tls/site-a/site-a.crt"
SITE_A_CLIENT_KEY="/etc/federation-tls/site-a/site-a.key"

MASTER_LOG="$LOGS/master.log"
FAILED_LOG="$LOGS/failed-runs.log"

mkdir -p "$RESULTS" "$LOGS" "$DATA" "$CERTS"
touch "$MASTER_LOG" "$FAILED_LOG"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" | tee -a "$MASTER_LOG"
}

section() {
  echo | tee -a "$MASTER_LOG"
  echo "============================================================" | tee -a "$MASTER_LOG"
  echo "$*" | tee -a "$MASTER_LOG"
  echo "============================================================" | tee -a "$MASTER_LOG"
}

die() { log "ERROR: $*"; exit 1; }

pve_ssh() {
  ssh -i "$PVE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "${PVE_USER}@${PVE_HOST}" "$@"
}

router_ssh() {
  local router="$1"; shift
  ssh -i "$ROUTER_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "${ROUTER_USER}@${router}" "$@"
}

site_ssh() {
  local host="$1"; shift
  ssh -i "$VM_SSH_PRIVATE_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new "${VM_USER}@${host}" "$@"
}

site_scp() {
  local src="$1" host="$2" dst="$3"
  scp -i "$VM_SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      "$src" "${VM_USER}@${host}:${dst}"
}


wait_for_cloud_init_and_apt() {
  local host="$1"
  local name="$2"

  section "WAITING FOR CLOUD-INIT/APT: ${name}"

  site_ssh "$host" '
    set -Eeuo pipefail

    echo "Waiting for cloud-init to complete..."
    if command -v cloud-init >/dev/null 2>&1; then
        sudo cloud-init status --wait || true
        cloud-init status --long || true
    fi

    echo "Waiting for apt/dpkg locks..."

    for i in $(seq 1 120)
    do
        apt_busy=0

        pgrep -x apt-get >/dev/null 2>&1 && apt_busy=1
        pgrep -x apt >/dev/null 2>&1 && apt_busy=1
        pgrep -x dpkg >/dev/null 2>&1 && apt_busy=1

        sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && apt_busy=1 || true
        sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 && apt_busy=1 || true
        sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1 && apt_busy=1 || true
        sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 && apt_busy=1 || true

        if [ "$apt_busy" -eq 0 ]; then
            echo "apt/dpkg is free."
            exit 0
        fi

        echo "apt/dpkg busy... ${i}/120"
        sleep 5
    done

    echo "Timed out waiting for apt/dpkg locks." >&2
    exit 1
  '
}

verify_ceph_storage() {
  section "VERIFYING CEPH STORAGE"
  local block
  block="$(pve_ssh "
    awk -v storage='${PVE_STORAGE}' '
      \$2 == storage { found=1; print; next }
      found && /^[^[:space:]]/ { exit }
      found { print }
    ' /etc/pve/storage.cfg
  ")"
  echo "$block" | tee -a "$MASTER_LOG"

  echo "$block" | grep -qE "^rbd:[[:space:]]+${PVE_STORAGE}$" \
    || die "Storage ${PVE_STORAGE} is not an RBD entry."

  echo "$block" | grep -qE '^[[:space:]]*content[[:space:]].*images' \
    || die "Storage ${PVE_STORAGE} does not advertise images content."

  pve_ssh "pvesm status | awk '\$1==\"${PVE_STORAGE}\" {print}'" | tee -a "$MASTER_LOG"
  log "Ceph storage ${PVE_STORAGE}: VERIFIED"
}

assert_ip_free_or_owned() {
  local ip="$1" vmid="$2"
  if pve_ssh "qm config ${vmid}" >/dev/null 2>&1; then
    return 0
  fi
  if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
    die "IP ${ip} is already responding while VM ${vmid} does not exist."
  fi
}

preflight() {
  section "PREFLIGHT"

  [ "$(id -u)" -eq 0 ] || die "Run as root."
  [ "$(hostname)" = "a-core" ] || die "Run on a-core."

  for c in ssh scp curl jq openssl awk sed ping python3 sha256sum; do
    command -v "$c" >/dev/null || die "Missing command: $c"
  done

  [ -r "$PVE_SSH_KEY" ] || die "Missing Proxmox key $PVE_SSH_KEY"
  [ -r "$ROUTER_SSH_KEY" ] || die "Missing router key $ROUTER_SSH_KEY"
  [ -r "$VM_SSH_PRIVATE_KEY" ] || die "Missing VM key $VM_SSH_PRIVATE_KEY"
  [ -r "$VM_SSH_PUBLIC_KEY" ] || die "Missing VM public key $VM_SSH_PUBLIC_KEY"
  [ -x "$AGENT_BINARY" ] || die "Missing agent binary $AGENT_BINARY"
  [ -x "$TOKEN_SCRIPT" ] || die "Missing token helper $TOKEN_SCRIPT"
  [ -x "$OPA_BINARY" ] || die "Missing OPA binary $OPA_BINARY"
  [ -r "$OPA_POLICY" ] || die "Missing OPA policy $OPA_POLICY"
  [ -r "$FED_CA_CERT" ] || die "Missing CA cert"
  [ -r "$FED_CA_KEY" ] || die "Missing CA key"
  [ -r "$SITE_A_CLIENT_CERT" ] || die "Missing Site A cert"
  [ -r "$SITE_A_CLIENT_KEY" ] || die "Missing Site A key"

  local cert_hash key_hash
  cert_hash="$(openssl x509 -in "$FED_CA_CERT" -pubkey -noout \
    | openssl pkey -pubin -outform der 2>/dev/null | sha256sum | awk '{print $1}')"
  key_hash="$(openssl pkey -in "$FED_CA_KEY" -pubout -outform der 2>/dev/null \
    | sha256sum | awk '{print $1}')"
  [ "$cert_hash" = "$key_hash" ] || die "CA certificate and private key do not match."
  log "Federation CA key pair: VERIFIED"

  pve_ssh 'hostname; pveversion' >/dev/null || die "Proxmox SSH failed."
  log "Proxmox SSH: PASS"

  pve_ssh "qm config ${TEMPLATE_VMID} | grep -q '^template: 1$'" \
    || die "VM ${TEMPLATE_VMID} is not a template."
  pve_ssh "ip link show ${PVE_BRIDGE}" >/dev/null \
    || die "Bridge ${PVE_BRIDGE} missing."

  verify_ceph_storage

  router_ssh "$ROUTER_A" 'hostname; sudo -n true' >/dev/null \
    || die "Router A SSH/sudo failed."
  router_ssh "$ROUTER_B" 'hostname; sudo -n true' >/dev/null \
    || die "Router B SSH/sudo failed."
  log "Router A/B SSH + sudo: PASS"

  assert_ip_free_or_owned "$SITE_C_MGMT" "$SITE_C_VMID"
  assert_ip_free_or_owned "$SITE_D_MGMT" "$SITE_D_VMID"
  assert_ip_free_or_owned "$SITE_E_MGMT" "$SITE_E_VMID"

  ping -c 1 -W 2 "$VM_GATEWAY" >/dev/null || die "Gateway ${VM_GATEWAY} unreachable."

  scp -i "$PVE_SSH_KEY" -o BatchMode=yes "$VM_SSH_PUBLIC_KEY" \
      "${PVE_USER}@${PVE_HOST}:/root/federation-fredrick.pub" >/dev/null

  log "Preflight complete."
}

install_router_ddil_helper() {
  local router="$1"
  router_ssh "$router" "sudo -n mkdir -p /opt/ddil"
  router_ssh "$router" "sudo -n tee /opt/ddil/set-latency-only.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
DEV=\"eth2\"
PROFILE=\"\${1:-baseline}\"
sudo tc qdisc del dev \"\$DEV\" root 2>/dev/null || true
case \"\$PROFILE\" in
  baseline) echo \"No artificial latency\" ;;
  mild) sudo tc qdisc add dev \"\$DEV\" root netem delay 25ms ;;
  moderate) sudo tc qdisc add dev \"\$DEV\" root netem delay 50ms ;;
  severe) sudo tc qdisc add dev \"\$DEV\" root netem delay 100ms ;;
  extreme) sudo tc qdisc add dev \"\$DEV\" root netem delay 250ms ;;
  *) echo \"Unknown profile: \$PROFILE\" >&2; exit 1 ;;
esac
tc qdisc show dev \"\$DEV\"
EOF
sudo -n chmod 0755 /opt/ddil/set-latency-only.sh"
}

install_router_helpers() {
  section "INSTALLING/VERIFYING ROUTER DDIL HELPERS"
  install_router_ddil_helper "$ROUTER_A"
  install_router_ddil_helper "$ROUTER_B"
  log "Router DDIL helpers installed."
}

create_vm() {
  local vmid="$1" name="$2" mgmt_ip="$3"
  section "PROVISIONING ${name} (${vmid})"

  if pve_ssh "qm config ${vmid}" >/dev/null 2>&1; then
    local existing_name
    existing_name="$(pve_ssh "qm config ${vmid}" | awk -F': ' '/^name:/ {print $2}')"
    [ "$existing_name" = "$name" ] \
      || die "VMID ${vmid} belongs to '${existing_name}', expected '${name}'."
    log "Existing ${vmid}/${name} found; clone skipped."
  else
    log "Cloning template ${TEMPLATE_VMID} -> ${vmid}/${name} on ${PVE_STORAGE}"
    pve_ssh "qm clone ${TEMPLATE_VMID} ${vmid} \
      --name ${name} --full 1 --storage ${PVE_STORAGE}"
    log "Clone complete."
  fi

  pve_ssh "qm stop ${vmid}" >/dev/null 2>&1 || true

  for _ in $(seq 1 30); do
    pve_ssh "qm status ${vmid}" | grep -q 'status: stopped' && break
    sleep 2
  done

  pve_ssh "qm set ${vmid} \
    --cores ${DEFAULT_CORES} \
    --memory ${DEFAULT_MEMORY} \
    --agent enabled=1 \
    --ciuser '${VM_USER}' \
    --cipassword '${VM_PASSWORD}' \
    --nameserver '${VM_DNS}' \
    --ipconfig0 'ip=${mgmt_ip}/${VM_PREFIX},gw=${VM_GATEWAY}' \
    --sshkeys /root/federation-fredrick.pub"

  if [ -n "$PVE_VLAN" ]; then
    pve_ssh "qm set ${vmid} --net0 'virtio,bridge=${PVE_BRIDGE},tag=${PVE_VLAN}'"
  else
    pve_ssh "qm set ${vmid} --net0 'virtio,bridge=${PVE_BRIDGE}'"
  fi

  pve_ssh "qm resize ${vmid} scsi0 ${DISK_SIZE}" >/dev/null 2>&1 || true
  pve_ssh "qm cloudinit update ${vmid}"

  pve_ssh "qm config ${vmid} | grep -E \
    '^(name|agent|ciuser|cipassword|ipconfig0|nameserver|net0|scsi0|memory|cores):'" \
    | tee -a "$MASTER_LOG"

  pve_ssh "qm config ${vmid} | grep '^scsi0:'" | grep -q "$PVE_STORAGE" \
    || die "${name}: scsi0 is not on ${PVE_STORAGE}."

  pve_ssh "qm start ${vmid}"
  log "${name} started with static IP ${mgmt_ip}/${VM_PREFIX}"
}

wait_for_ssh() {
  local host="$1" name="$2"
  section "WAITING FOR SSH: ${name}"
  for i in $(seq 1 90); do
    if site_ssh "$host" hostname >/dev/null 2>&1; then
      log "${name} SSH ready at ${host}"
      site_ssh "$host" 'cloud-init status --long 2>/dev/null || true' \
        >"$LOGS/${name}-cloud-init-status.txt" 2>&1 || true
      return 0
    fi
    log "${name}: waiting ${i}/90"
    sleep 5
  done
  die "${name} did not become reachable."
}

install_and_verify_qemu_agent() {
  local vmid="$1" host="$2" name="$3"
  section "QEMU GUEST AGENT: ${name}"

  wait_for_cloud_init_and_apt "$host" "$name"

  site_ssh "$host" '
    set -Eeuo pipefail

    sudo dpkg --configure -a || true

    for attempt in 1 2 3
    do
        if sudo apt-get update &&
           sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-guest-agent
        then
            break
        fi

        if [ "$attempt" -eq 3 ]; then
            echo "qemu-guest-agent installation failed after 3 attempts." >&2
            exit 1
        fi

        echo "apt install failed; waiting before retry ${attempt}/3..."
        sleep 15
    done

    sudo systemctl enable --now qemu-guest-agent
    sudo systemctl is-active qemu-guest-agent
  '

  sleep 5

  local ok=0
  for _ in $(seq 1 30); do
    if pve_ssh "qm guest cmd ${vmid} network-get-interfaces" \
        >"$LOGS/${name}-guest-interfaces.json" 2>/dev/null; then
      ok=1
      break
    fi
    sleep 2
  done

  [ "$ok" -eq 1 ] || die "QEMU guest agent unavailable for ${name}."
  grep -q "\"ip-address\" : \"${host}\"" "$LOGS/${name}-guest-interfaces.json" \
    || die "${name}: expected IP ${host} not reported by guest agent."

  site_ssh "$host" \
    "ip -4 addr; echo; ip route; echo; systemctl is-active qemu-guest-agent" \
    >"$LOGS/${name}-network-and-agent.txt"

  log "${name}: static IP + qemu-guest-agent VERIFIED"
}

generate_site_cert() {
  local site="$1" mgmt_ip="$2" private_ip="$3"
  section "CERTIFICATE: ${site}"
  mkdir -p "$CERTS/$site"
  rm -f "$CERTS/$site/$site.key" "$CERTS/$site/$site.csr" "$CERTS/$site/$site.crt"

  openssl genrsa -out "$CERTS/$site/$site.key" 2048
  openssl req -new -key "$CERTS/$site/$site.key" \
      -out "$CERTS/$site/$site.csr" \
      -subj "/C=UG/O=Federated Genomics Lab/OU=${site}/CN=${site}"

  cat >"$CERTS/$site/extensions.cnf" <<EOF
subjectAltName=DNS:${site},IP:${mgmt_ip},IP:${private_ip}
extendedKeyUsage=serverAuth,clientAuth
keyUsage=digitalSignature,keyEncipherment
EOF

  openssl x509 -req -in "$CERTS/$site/$site.csr" \
      -CA "$FED_CA_CERT" -CAkey "$FED_CA_KEY" -CAcreateserial \
      -out "$CERTS/$site/$site.crt" -days 825 -sha256 \
      -extfile "$CERTS/$site/extensions.cnf"

  openssl verify -CAfile "$FED_CA_CERT" "$CERTS/$site/$site.crt"
  chmod 600 "$CERTS/$site/$site.key"
}

deploy_site() {
  local site="$1" host="$2" private_ip="$3" dataset="$4"
  section "DEPLOYING FEDERATION STACK: ${site}"

  generate_site_cert "$site" "$host" "$private_ip"

  site_scp "$AGENT_BINARY" "$host" /tmp/federation-agent
  site_scp "$OPA_BINARY" "$host" /tmp/opa
  site_scp "$OPA_POLICY" "$host" /tmp/genomics.rego
  site_scp "$CERTS/$site/$site.crt" "$host" "/tmp/${site}.crt"
  site_scp "$CERTS/$site/$site.key" "$host" "/tmp/${site}.key"

  cp "$FED_CA_CERT" /tmp/federation-ca.crt
  chmod 0644 /tmp/federation-ca.crt
  site_scp /tmp/federation-ca.crt "$host" /tmp/ca.crt
  rm -f /tmp/federation-ca.crt

  site_ssh "$host" "bash -s -- '$site' '$dataset'" <<'REMOTE'
set -Eeuo pipefail
SITE="$1"
DATASET="$2"

echo "Waiting for cloud-init to finish..."
if command -v cloud-init >/dev/null 2>&1
then
    sudo cloud-init status --wait || true
fi

echo "Waiting for apt/dpkg locks before federation deployment..."

for i in $(seq 1 120)
do
    apt_busy=0

    pgrep -x apt-get >/dev/null 2>&1 && apt_busy=1
    pgrep -x apt >/dev/null 2>&1 && apt_busy=1
    pgrep -x dpkg >/dev/null 2>&1 && apt_busy=1

    sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && apt_busy=1 || true
    sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 && apt_busy=1 || true
    sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1 && apt_busy=1 || true
    sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 && apt_busy=1 || true

    if [ "$apt_busy" -eq 0 ]; then
        echo "apt/dpkg is free."
        break
    fi

    if [ "$i" -eq 120 ]; then
        echo "Timed out waiting for apt/dpkg locks." >&2
        exit 1
    fi

    echo "apt/dpkg busy... ${i}/120"
    sleep 5
done

sudo dpkg --configure -a || true

for attempt in 1 2 3
do
    if sudo apt-get update &&
       sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
         nginx curl jq sqlite3 iproute2 iputils-ping qemu-guest-agent
    then
        break
    fi

    if [ "$attempt" -eq 3 ]; then
        echo "Package installation failed after 3 attempts." >&2
        exit 1
    fi

    echo "Package installation failed; retrying after 15 seconds..."
    sleep 15
done

sudo systemctl enable --now qemu-guest-agent

sudo mkdir -p \
  /etc/federation-agent \
  /etc/federation-tls/ca \
  "/etc/federation-tls/${SITE}" \
  /etc/opa \
  /genomics/work/federation/logs \
  "/genomics/work/nextflow-${SITE}"

sudo install -o root -g root -m 0755 /tmp/federation-agent /usr/local/bin/federation-agent
sudo install -o root -g root -m 0755 /tmp/opa /usr/local/bin/opa
sudo install -o root -g root -m 0644 /tmp/genomics.rego /etc/opa/genomics.rego
sudo install -o root -g root -m 0644 /tmp/ca.crt /etc/federation-tls/ca/ca.crt
sudo install -o root -g root -m 0644 "/tmp/${SITE}.crt" "/etc/federation-tls/${SITE}/${SITE}.crt"
sudo install -o root -g root -m 0600 "/tmp/${SITE}.key" "/etc/federation-tls/${SITE}/${SITE}.key"

sudo tee /etc/systemd/system/opa.service >/dev/null <<'EOF'
[Unit]
Description=Open Policy Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/opa run --server --addr=127.0.0.1:8181 /etc/opa/genomics.rego
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/federation-agent/site.env >/dev/null <<EOF
SITE_ID=${SITE}
DATASET_ID=${DATASET}
LISTEN_ADDR=127.0.0.1:8080
PIPELINE_DIR=/genomics/work/nextflow-${SITE}
DATABASE_PATH=/genomics/work/federation/jobs.db
OPA_URL=http://127.0.0.1:8181/v1/data/genomics/authz/allow
SITE_A_ISSUER=https://10.10.10.10:9443/realms/genomics
SITE_B_ISSUER=https://10.20.20.10:9443/realms/genomics
KEYCLOAK_CA_PATH=/etc/federation-tls/ca/ca.crt
JWT_AUDIENCE=federation-api
EOF

sudo tee /etc/systemd/system/federation-agent.service >/dev/null <<'EOF'
[Unit]
Description=Federated Genomics Rust Agent
After=network-online.target opa.service
Wants=network-online.target
Requires=opa.service

[Service]
Type=simple
EnvironmentFile=/etc/federation-agent/site.env
ExecStart=/usr/local/bin/federation-agent
Restart=always
RestartSec=5
User=fredrick
Group=fredrick

[Install]
WantedBy=multi-user.target
EOF

sudo chown -R fredrick:fredrick /genomics/work
sudo systemctl daemon-reload
sudo systemctl enable --now opa federation-agent
sleep 5
systemctl is-active opa
systemctl is-active federation-agent
curl -fsS http://127.0.0.1:8080/health | jq
REMOTE

  log "${site}: federation stack deployed."
}

configure_nginx() {
  local site="$1" host="$2"
  section "NGINX MTLS: ${site}"

  site_ssh "$host" "bash -s -- '$site' '$host'" <<'REMOTE'
set -Eeuo pipefail
SITE="$1"
MGMT_IP="$2"

sudo tee "/etc/nginx/sites-available/federation-${SITE}" >/dev/null <<EOF
server {
  listen ${MGMT_IP}:8443 ssl;
  server_name ${SITE};

  ssl_certificate /etc/federation-tls/${SITE}/${SITE}.crt;
  ssl_certificate_key /etc/federation-tls/${SITE}/${SITE}.key;
  ssl_client_certificate /etc/federation-tls/ca/ca.crt;
  ssl_verify_client on;
  ssl_protocols TLSv1.2 TLSv1.3;

  location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }
}
EOF

sudo ln -sf "/etc/nginx/sites-available/federation-${SITE}" \
             "/etc/nginx/sites-enabled/federation-${SITE}"
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
ss -lnt | grep "${MGMT_IP}:8443"
REMOTE

  curl -fsS --cacert "$FED_CA_CERT" \
       --cert "$SITE_A_CLIENT_CERT" \
       --key "$SITE_A_CLIENT_KEY" \
       "https://${host}:8443/health" \
       | jq | tee "$LOGS/${site}-mtls-health.json"

  local no_mtls
  no_mtls="$(curl -s -o /dev/null -w '%{http_code}' \
      --cacert "$FED_CA_CERT" "https://${host}:8443/health" || true)"

  case "$no_mtls" in
    400|403) ;;
    *) die "${site}: expected no-mTLS rejection, got HTTP ${no_mtls}" ;;
  esac
}

set_new_site_ddil() {
  local host="$1" profile="$2"
  local delay
  delay="$(ddil_delay_ms "$profile")"

  if [ "$delay" = "0" ]; then
    site_ssh "$host" "sudo tc qdisc del dev eth0 root 2>/dev/null || true; tc qdisc show dev eth0"
  else
    site_ssh "$host" "sudo tc qdisc replace dev eth0 root netem delay ${delay}ms; tc qdisc show dev eth0"
  fi
}

set_router_ddil() {
  local profile="$1"
  router_ssh "$ROUTER_A" "sudo -n /opt/ddil/set-latency-only.sh '${profile}'" >/dev/null
  router_ssh "$ROUTER_B" "sudo -n /opt/ddil/set-latency-only.sh '${profile}'" >/dev/null
}

reset_all_ddil() {
  set_router_ddil baseline >/dev/null 2>&1 || true
  for ip in "$SITE_C_MGMT" "$SITE_D_MGMT" "$SITE_E_MGMT"; do
    if site_ssh "$ip" true >/dev/null 2>&1; then
      set_new_site_ddil "$ip" baseline >/dev/null 2>&1 || true
    fi
  done
}

measure_control() {
  local site="$1" target="$2" profile="$3" site_count="$4"
  local file="$DATA/control-sites${site_count}-${site}-${profile}.csv"

  echo "run,site_count,site,condition,http_code,total_ms" >"$file"

  for run in $(seq 1 "$CONTROL_REPETITIONS"); do
    local token result code sec ms
    token="$("$TOKEN_SCRIPT")"

    result="$(curl -s -o /dev/null -w '%{http_code},%{time_total}' \
      --cacert "$FED_CA_CERT" \
      --cert "$SITE_A_CLIENT_CERT" \
      --key "$SITE_A_CLIENT_KEY" \
      -X POST \
      -H "Authorization: Bearer ${token}" \
      "https://${target}:8443/raw-export")"

    code="${result%,*}"
    sec="${result#*,}"
    ms="$(awk -v s="$sec" 'BEGIN {printf "%.3f", s*1000}')"

    echo "${run},${site_count},${site},${profile},${code},${ms}" >>"$file"

    [ "$code" = "403" ] \
      || echo "${site_count},${site},${profile},${run},HTTP_${code}" >>"$FAILED_LOG"

    log "${site_count} sites | ${site} | ${profile} | run ${run}: ${ms} ms | HTTP ${code}"
    sleep 1
  done
}

run_site_count_experiment() {
  local count="$1"; shift
  local entries=("$@")
  section "FEDERATION SIZE = ${count}"

  for profile in "${DDIL_PROFILES[@]}"; do
    set_router_ddil "$profile"

    for entry in "${entries[@]}"; do
      local site="${entry%%:*}" target="${entry##*:}"
      case "$site" in
        site-c|site-d|site-e) set_new_site_ddil "$target" "$profile" ;;
      esac
    done

    sleep 3

    for entry in "${entries[@]}"; do
      local site="${entry%%:*}" target="${entry##*:}"
      ping -c 10 -W 3 "$target" >"$LOGS/ping-${count}sites-${site}-${profile}.txt" 2>&1 || true
      measure_control "$site" "$target" "$profile" "$count"
    done

    reset_all_ddil
    sleep 2
  done
}

wait_existing_site_b() {
  for _ in $(seq 1 90); do
    if ssh -i "$VM_SSH_PRIVATE_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
        "fredrick@${SITE_B_MGMT}" hostname >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  die "b-core did not return after resource change."
}

resize_site_b() {
  local profile="$1" cores="$2" memory="$3"
  section "SITE B RESOURCE PROFILE: ${profile}"

  pve_ssh "qm shutdown ${SITE_B_VMID} --timeout 120" || true

  for _ in $(seq 1 30); do
    pve_ssh "qm status ${SITE_B_VMID}" | grep -q 'status: stopped' && break
    sleep 2
  done

  if ! pve_ssh "qm status ${SITE_B_VMID}" | grep -q 'status: stopped'; then
    pve_ssh "qm stop ${SITE_B_VMID}"
  fi

  pve_ssh "qm set ${SITE_B_VMID} --cores ${cores} --memory ${memory}"
  pve_ssh "qm start ${SITE_B_VMID}"
  wait_existing_site_b
  sleep 10

  ssh -i "$VM_SSH_PRIVATE_KEY" -o BatchMode=yes "fredrick@${SITE_B_MGMT}" \
      'hostname; nproc; free -h; uptime' >"$LOGS/site-b-resource-${profile}.txt"
}

run_resource_experiment() {
  section "SITE B RESOURCE SCALING EXPERIMENT"
  set_router_ddil baseline

  for item in "${RESOURCE_PROFILES[@]}"; do
    IFS=: read -r profile cores memory <<<"$item"
    resize_site_b "$profile" "$cores" "$memory"

    local out="$DATA/resource-${profile}.csv"
    echo "run,profile,cores,memory_mb,http_code,total_ms" >"$out"

    for run in $(seq 1 "$CONTROL_REPETITIONS"); do
      local token result code sec ms
      token="$("$TOKEN_SCRIPT")"
      result="$(curl -s -o /dev/null -w '%{http_code},%{time_total}' \
        --cacert "$FED_CA_CERT" \
        --cert "$SITE_A_CLIENT_CERT" \
        --key "$SITE_A_CLIENT_KEY" \
        -X POST -H "Authorization: Bearer ${token}" \
        "https://${SITE_B_PRIVATE}:8443/raw-export")"
      code="${result%,*}"
      sec="${result#*,}"
      ms="$(awk -v s="$sec" 'BEGIN {printf "%.3f", s*1000}')"
      echo "${run},${profile},${cores},${memory},${code},${ms}" >>"$out"
      log "resource=${profile} run=${run}: ${ms} ms HTTP ${code}"
    done
  done
}

restore_site_b() {
  section "RESTORING SITE B DEFAULT RESOURCES"
  resize_site_b "restored-default" "$DEFAULT_CORES" "$DEFAULT_MEMORY"
}

generate_results() {
  section "GENERATING RESULTS"

  python3 - "$DATA" "$RESULTS" <<'PY'
import csv, glob, math, os, statistics, sys

data_dir, results_dir = sys.argv[1], sys.argv[2]
order = ["baseline","mild","moderate","severe","extreme"]

rows = []
for path in glob.glob(os.path.join(data_dir, "control-sites*.csv")):
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            try:
                rows.append({
                    "site_count": int(r["site_count"]),
                    "site": r["site"],
                    "condition": r["condition"],
                    "http_code": int(r["http_code"]),
                    "total_ms": float(r["total_ms"]),
                })
            except Exception:
                pass

groups = {}
for r in rows:
    groups.setdefault((r["site_count"],r["site"],r["condition"]), []).append(r)

out = os.path.join(results_dir, "federation-scale-summary.csv")
with open(out, "w", newline="") as f:
    fields = ["site_count","site","condition","n","expected_403_percent",
              "mean_ms","median_ms","p95_ms","p99_ms","std_ms"]
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()

    for key in sorted(groups, key=lambda k:(k[0],k[1],order.index(k[2]))):
        g = groups[key]
        vals = sorted(x["total_ms"] for x in g)

        def q(p):
            if len(vals) == 1: return vals[0]
            pos = (len(vals)-1)*p
            lo, hi = math.floor(pos), math.ceil(pos)
            if lo == hi: return vals[lo]
            return vals[lo] + (vals[hi]-vals[lo])*(pos-lo)

        n = len(vals)
        w.writerow({
            "site_count": key[0],
            "site": key[1],
            "condition": key[2],
            "n": n,
            "expected_403_percent": round(sum(1 for x in g if x["http_code"]==403)/n*100,2),
            "mean_ms": round(statistics.mean(vals),3),
            "median_ms": round(statistics.median(vals),3),
            "p95_ms": round(q(.95),3),
            "p99_ms": round(q(.99),3),
            "std_ms": round(statistics.stdev(vals) if n>1 else 0,3),
        })

print(out)
PY

  command -v column >/dev/null 2>&1 && \
    column -t -s, "$RESULTS/federation-scale-summary.csv" \
      | tee "$RESULTS/federation-scale-summary.txt" || true
}

cleanup() {
  log "Cleanup: resetting DDIL to baseline."
  reset_all_ddil || true
}
trap cleanup EXIT INT TERM

# ============================================================
# MAIN
# ============================================================

preflight
install_router_helpers

if [ "$RUN_TWO_SITE_EXPERIMENT" = "yes" ]; then
  run_site_count_experiment 2 "site-b:${SITE_B_PRIVATE}"
else
  section "SKIPPING 2-SITE TEST"
  log "Existing two-site DDIL results preserved; no repeat requested."
fi

create_vm "$SITE_C_VMID" "site-c" "$SITE_C_MGMT"
wait_for_ssh "$SITE_C_MGMT" "site-c"
install_and_verify_qemu_agent "$SITE_C_VMID" "$SITE_C_MGMT" "site-c"
deploy_site "site-c" "$SITE_C_MGMT" "$SITE_C_PRIVATE" "$SITE_C_DATASET"
configure_nginx "site-c" "$SITE_C_MGMT"

run_site_count_experiment 3 \
  "site-b:${SITE_B_PRIVATE}" \
  "site-c:${SITE_C_MGMT}"

create_vm "$SITE_D_VMID" "site-d" "$SITE_D_MGMT"
wait_for_ssh "$SITE_D_MGMT" "site-d"
install_and_verify_qemu_agent "$SITE_D_VMID" "$SITE_D_MGMT" "site-d"
deploy_site "site-d" "$SITE_D_MGMT" "$SITE_D_PRIVATE" "$SITE_D_DATASET"
configure_nginx "site-d" "$SITE_D_MGMT"

run_site_count_experiment 4 \
  "site-b:${SITE_B_PRIVATE}" \
  "site-c:${SITE_C_MGMT}" \
  "site-d:${SITE_D_MGMT}"

create_vm "$SITE_E_VMID" "site-e" "$SITE_E_MGMT"
wait_for_ssh "$SITE_E_MGMT" "site-e"
install_and_verify_qemu_agent "$SITE_E_VMID" "$SITE_E_MGMT" "site-e"
deploy_site "site-e" "$SITE_E_MGMT" "$SITE_E_PRIVATE" "$SITE_E_DATASET"
configure_nginx "site-e" "$SITE_E_MGMT"

run_site_count_experiment 5 \
  "site-b:${SITE_B_PRIVATE}" \
  "site-c:${SITE_C_MGMT}" \
  "site-d:${SITE_D_MGMT}" \
  "site-e:${SITE_E_MGMT}"

reset_all_ddil

if [ "$RUN_RESOURCE_EXPERIMENT" = "yes" ]; then
  run_resource_experiment
  restore_site_b
fi

reset_all_ddil
generate_results

trap - EXIT INT TERM

section "EXPERIMENT COMPLETE"

echo "Ceph storage: ${PVE_STORAGE}"
echo "Site C: VMID ${SITE_C_VMID}, ${SITE_C_MGMT}/${VM_PREFIX}"
echo "Site D: VMID ${SITE_D_VMID}, ${SITE_D_MGMT}/${VM_PREFIX}"
echo "Site E: VMID ${SITE_E_VMID}, ${SITE_E_MGMT}/${VM_PREFIX}"
echo "Summary: ${RESULTS}/federation-scale-summary.csv"
echo "Logs: ${LOGS}"

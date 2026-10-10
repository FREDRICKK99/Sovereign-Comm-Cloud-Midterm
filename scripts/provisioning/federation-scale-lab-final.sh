#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# FEDERATED GENOMICS SCALE + DDIL + RESOURCE EXPERIMENT
#
# Run on: a-core as root
#
# What this script does:
#   - validates Proxmox/template/storage/CA/SSH prerequisites
#   - clones Site C/D/E from Proxmox cloud-init template 9000
#   - enforces static management IPs
#   - sets cloud-init user/password and SSH key
#   - enables + verifies QEMU guest agent
#   - deploys OPA, Rust federation agent, Nginx mTLS, certificates
#   - adds sites one at a time (2 -> 3 -> 4 -> 5)
#   - runs latency-only DDIL control-plane tests
#   - varies Site B CPU/RAM resources
#   - records raw CSVs, logs, summaries and PNG plots
#   - restores Site B resources and resets DDIL on exit
#
# IMPORTANT:
#   - This does NOT rewrite /etc/network/interfaces on Proxmox.
#   - New sites use their STATIC MANAGEMENT IP for the HTTPS
#     federation frontend. Their 10.x addresses remain logical
#     site-private addresses until you attach/rout a private NIC.
#   - The script never changes measured results to force a trend.
# ============================================================

# ============================================================
# FIXED LAB CONFIGURATION
# ============================================================

# ---------- Proxmox ----------
PVE_HOST="137.63.148.11"
PVE_USER="root"
PVE_SSH_KEY="/root/.ssh/id_ed25519"

TEMPLATE_VMID="9000"
PVE_STORAGE="MujhuNAS"
PVE_BRIDGE="vmbr0"
PVE_VLAN=""

# ---------- Existing federation ----------
SITE_A_MGMT="137.63.148.73"
SITE_A_PRIVATE="10.10.10.10"

SITE_B_MGMT="137.63.148.42"
SITE_B_PRIVATE="10.20.20.10"
SITE_B_VMID="606"

ROUTER_A="137.63.148.179"
ROUTER_B="137.63.148.26"
ROUTER_USER="fredrick"
ROUTER_SSH_KEY="/home/fredrick/.ssh/id_rsa"

# ---------- New sites ----------
SITE_C_VMID="230"
SITE_D_VMID="240"
SITE_E_VMID="250"

SITE_C_MGMT="137.63.148.104"
SITE_D_MGMT="137.63.148.105"
SITE_E_MGMT="137.63.148.106"

SITE_C_PRIVATE="10.30.30.10"
SITE_D_PRIVATE="10.40.40.10"
SITE_E_PRIVATE="10.50.50.10"

SITE_C_DATASET="dataset-c-001"
SITE_D_DATASET="dataset-d-001"
SITE_E_DATASET="dataset-e-001"

# ---------- Cloud-init ----------
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

# ---------- Site B resource experiment ----------
RESOURCE_PROFILES=(
    "small:2:4096"
    "medium:4:8192"
    "large:8:16384"
)

# ---------- Experiments ----------
CONTROL_REPETITIONS="10"

DDIL_PROFILES=(
    baseline
    mild
    moderate
    severe
    extreme
)

# Latency-only test values.
# We deliberately do NOT mix loss/rate into this experiment.
ddil_delay_ms() {
    case "$1" in
        baseline) echo "0" ;;
        mild)     echo "25" ;;
        moderate) echo "50" ;;
        severe)   echo "100" ;;
        extreme)  echo "250" ;;
        *) return 1 ;;
    esac
}

# ---------- Local deployment files ----------
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

# ============================================================
# HELPERS
# ============================================================

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" \
        | tee -a "$MASTER_LOG"
}

section() {
    echo | tee -a "$MASTER_LOG"
    echo "============================================================" | tee -a "$MASTER_LOG"
    echo "$*" | tee -a "$MASTER_LOG"
    echo "============================================================" | tee -a "$MASTER_LOG"
}

die() {
    log "ERROR: $*"
    exit 1
}

pve_ssh() {
    ssh \
        -i "$PVE_SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "${PVE_USER}@${PVE_HOST}" \
        "$@"
}

router_ssh() {
    local router="$1"
    shift

    ssh \
        -i "$ROUTER_SSH_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "${ROUTER_USER}@${router}" \
        "$@"
}

site_ssh() {
    local host="$1"
    shift

    ssh \
        -i "$VM_SSH_PRIVATE_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "${VM_USER}@${host}" \
        "$@"
}

site_scp() {
    local src="$1"
    local host="$2"
    local dst="$3"

    scp \
        -i "$VM_SSH_PRIVATE_KEY" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$src" \
        "${VM_USER}@${host}:${dst}"
}

assert_ip_free() {
    local ip="$1"

    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        die "Static IP ${ip} is already answering ping. Choose a free address."
    fi
}

# ============================================================
# PREFLIGHT
# ============================================================

preflight() {
    section "PREFLIGHT"

    [ "$(id -u)" -eq 0 ] || die "Run this script as root on a-core."
    [ "$(hostname)" = "a-core" ] || die "Run this script on a-core."

    for cmd in ssh scp curl jq openssl awk sed ping python3 sha256sum; do
        command -v "$cmd" >/dev/null || die "Missing command: $cmd"
    done

    [ -r "$PVE_SSH_KEY" ] || die "Missing Proxmox SSH key: $PVE_SSH_KEY"
    [ -r "$ROUTER_SSH_KEY" ] || die "Missing router SSH key: $ROUTER_SSH_KEY"
    [ -r "$VM_SSH_PRIVATE_KEY" ] || die "Missing VM SSH private key: $VM_SSH_PRIVATE_KEY"
    [ -r "$VM_SSH_PUBLIC_KEY" ] || die "Missing VM SSH public key: $VM_SSH_PUBLIC_KEY"

    [ -x "$AGENT_BINARY" ] || die "Missing Rust federation binary: $AGENT_BINARY"
    [ -x "$TOKEN_SCRIPT" ] || die "Missing token script: $TOKEN_SCRIPT"
    [ -x "$OPA_BINARY" ] || die "Missing OPA binary: $OPA_BINARY"
    [ -r "$OPA_POLICY" ] || die "Missing OPA policy: $OPA_POLICY"

    [ -r "$FED_CA_CERT" ] || die "Missing federation CA certificate: $FED_CA_CERT"
    [ -r "$FED_CA_KEY" ] || die "Missing federation CA private key: $FED_CA_KEY"

    [ -r "$SITE_A_CLIENT_CERT" ] || die "Missing Site A client certificate"
    [ -r "$SITE_A_CLIENT_KEY" ] || die "Missing Site A client key"

    # Verify CA certificate/private-key pair really match.
    local cert_hash key_hash
    cert_hash="$(
        openssl x509 -in "$FED_CA_CERT" -pubkey -noout \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | sha256sum | awk '{print $1}'
    )"
    key_hash="$(
        openssl pkey -in "$FED_CA_KEY" -pubout -outform der 2>/dev/null \
        | sha256sum | awk '{print $1}'
    )"

    [ "$cert_hash" = "$key_hash" ] \
        || die "Federation ca.crt and ca.key do not match."

    log "Federation CA key pair: VERIFIED"

    pve_ssh 'hostname; pveversion' >/dev/null \
        || die "Cannot reach Proxmox non-interactively."

    log "Proxmox SSH: PASS"

    pve_ssh "qm config ${TEMPLATE_VMID} | grep -q '^template: 1$'" \
        || die "VM ${TEMPLATE_VMID} is not a Proxmox template."

    pve_ssh "ip link show ${PVE_BRIDGE}" >/dev/null \
        || die "Proxmox bridge ${PVE_BRIDGE} does not exist."

    pve_ssh "grep -A8 -B2 '^nfs: ${PVE_STORAGE}' /etc/pve/storage.cfg | grep -q 'content.*images'" \
        || die "Storage ${PVE_STORAGE} does not advertise 'images' content."

    log "Storage ${PVE_STORAGE}: supports VM images"

    # Make sure the root-run automation can operate both routers.
    router_ssh "$ROUTER_A" 'hostname; sudo -n true' >/dev/null \
        || die "Router A SSH/sudo failed."

    router_ssh "$ROUTER_B" 'hostname; sudo -n true' >/dev/null \
        || die "Router B SSH/sudo failed. Install /home/fredrick/.ssh/id_rsa.pub on router-b first."

    log "Router A/B SSH + passwordless sudo: PASS"

    # Verify the selected management IPs are not already in use.
    assert_ip_free "$SITE_C_MGMT"
    assert_ip_free "$SITE_D_MGMT"
    assert_ip_free "$SITE_E_MGMT"

    ping -c 1 -W 2 "$VM_GATEWAY" >/dev/null \
        || die "VM gateway ${VM_GATEWAY} is unreachable."

    # Copy Fredrick's public SSH key to the Proxmox node for qm --sshkeys.
    scp \
        -i "$PVE_SSH_KEY" \
        -o BatchMode=yes \
        "$VM_SSH_PUBLIC_KEY" \
        "${PVE_USER}@${PVE_HOST}:/root/federation-fredrick.pub" \
        >/dev/null

    log "Preflight complete."
}

# ============================================================
# DDIL HELPER INSTALLATION
# ============================================================

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
    baseline)
        echo \"No artificial latency\"
        ;;
    mild)
        sudo tc qdisc add dev \"\$DEV\" root netem delay 25ms
        ;;
    moderate)
        sudo tc qdisc add dev \"\$DEV\" root netem delay 50ms
        ;;
    severe)
        sudo tc qdisc add dev \"\$DEV\" root netem delay 100ms
        ;;
    extreme)
        sudo tc qdisc add dev \"\$DEV\" root netem delay 250ms
        ;;
    *)
        echo \"Unknown profile: \$PROFILE\" >&2
        exit 1
        ;;
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

# ============================================================
# PROXMOX VM PROVISIONING
# ============================================================

create_vm() {
    local vmid="$1"
    local name="$2"
    local mgmt_ip="$3"

    section "PROVISIONING ${name} (${vmid})"

    if pve_ssh "qm status ${vmid}" >/dev/null 2>&1; then
        log "VM ${vmid} already exists; not cloning again."
    else
        log "Cloning template ${TEMPLATE_VMID} -> VM ${vmid}"

        pve_ssh \
            "qm clone ${TEMPLATE_VMID} ${vmid} \
             --name ${name} \
             --full 1 \
             --storage ${PVE_STORAGE}"
    fi

    # VM must be stopped while we enforce first-boot cloud-init settings.
    pve_ssh "qm stop ${vmid}" >/dev/null 2>&1 || true

    pve_ssh \
        "qm set ${vmid} \
         --cores ${DEFAULT_CORES} \
         --memory ${DEFAULT_MEMORY} \
         --agent enabled=1 \
         --ciuser '${VM_USER}' \
         --cipassword '${VM_PASSWORD}' \
         --nameserver '${VM_DNS}' \
         --ipconfig0 'ip=${mgmt_ip}/${VM_PREFIX},gw=${VM_GATEWAY}' \
         --sshkeys /root/federation-fredrick.pub"

    if [ -n "$PVE_VLAN" ]; then
        pve_ssh \
            "qm set ${vmid} \
             --net0 'virtio,bridge=${PVE_BRIDGE},tag=${PVE_VLAN}'"
    else
        pve_ssh \
            "qm set ${vmid} \
             --net0 'virtio,bridge=${PVE_BRIDGE}'"
    fi

    # Do not fail if the template disk is already >= requested size.
    pve_ssh "qm resize ${vmid} scsi0 ${DISK_SIZE}" >/dev/null 2>&1 || true

    # Explicitly regenerate cloud-init ISO after all values are set.
    pve_ssh "qm cloudinit update ${vmid}"

    log "Cloud-init configuration for ${name}:"
    pve_ssh \
        "qm config ${vmid} | grep -E '^(agent|ciuser|cipassword|ipconfig0|nameserver|net0|scsi0|memory|cores):'" \
        | tee -a "$MASTER_LOG"

    pve_ssh "qm start ${vmid}"

    log "${name} started with static management IP ${mgmt_ip}/${VM_PREFIX}"
}

# ============================================================
# WAIT FOR SSH + QEMU AGENT
# ============================================================

wait_for_ssh() {
    local host="$1"
    local name="$2"

    section "WAITING FOR SSH: ${name}"

    for i in $(seq 1 90); do
        if site_ssh "$host" hostname >/dev/null 2>&1; then
            log "${name} SSH ready on ${host}"
            return 0
        fi

        log "${name}: waiting for SSH ${i}/90"
        sleep 5
    done

    die "${name} never became reachable by SSH at ${host}"
}

install_and_verify_qemu_agent() {
    local vmid="$1"
    local host="$2"
    local name="$3"

    section "QEMU GUEST AGENT: ${name}"

    site_ssh "$host" \
        "sudo apt-get update &&
         sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-guest-agent &&
         sudo systemctl enable --now qemu-guest-agent"

    # Some qemu-guest-agent services use a virtio socket and can take a moment.
    sleep 5

    local ok=0
    for i in $(seq 1 30); do
        if pve_ssh "qm guest cmd ${vmid} network-get-interfaces" \
            >"$LOGS/${name}-guest-interfaces.json" 2>/dev/null
        then
            ok=1
            break
        fi
        sleep 2
    done

    [ "$ok" -eq 1 ] || die "QEMU Guest Agent did not become available for ${name}"

    grep -q "\"ip-address\" : \"${host}\"" "$LOGS/${name}-guest-interfaces.json" \
        || die "${name}: QEMU agent does not report expected static IP ${host}"

    site_ssh "$host" \
        "ip -4 addr; echo; ip route; echo; systemctl is-active qemu-guest-agent" \
        >"$LOGS/${name}-network-and-agent.txt"

    log "${name}: QEMU Guest Agent + static IP VERIFIED"
}

# ============================================================
# TLS CERTIFICATES
# ============================================================

generate_site_cert() {
    local site="$1"
    local mgmt_ip="$2"
    local private_ip="$3"

    section "CERTIFICATE: ${site}"

    mkdir -p "$CERTS/$site"

    # Always regenerate for this experiment so SANs match current addresses.
    rm -f \
        "$CERTS/$site/$site.key" \
        "$CERTS/$site/$site.csr" \
        "$CERTS/$site/$site.crt"

    openssl genrsa \
        -out "$CERTS/$site/$site.key" \
        2048

    openssl req \
        -new \
        -key "$CERTS/$site/$site.key" \
        -out "$CERTS/$site/$site.csr" \
        -subj "/C=UG/O=Federated Genomics Lab/OU=${site}/CN=${site}"

    cat >"$CERTS/$site/extensions.cnf" <<EOF
subjectAltName=DNS:${site},IP:${mgmt_ip},IP:${private_ip}
extendedKeyUsage=serverAuth,clientAuth
keyUsage=digitalSignature,keyEncipherment
EOF

    openssl x509 \
        -req \
        -in "$CERTS/$site/$site.csr" \
        -CA "$FED_CA_CERT" \
        -CAkey "$FED_CA_KEY" \
        -CAcreateserial \
        -out "$CERTS/$site/$site.crt" \
        -days 825 \
        -sha256 \
        -extfile "$CERTS/$site/extensions.cnf"

    openssl verify \
        -CAfile "$FED_CA_CERT" \
        "$CERTS/$site/$site.crt"

    chmod 600 "$CERTS/$site/$site.key"

    log "${site}: certificate generated for ${mgmt_ip} and ${private_ip}"
}

# ============================================================
# OPA + FEDERATION AGENT DEPLOYMENT
# ============================================================

deploy_site() {
    local site="$1"
    local host="$2"
    local private_ip="$3"
    local dataset="$4"

    section "DEPLOYING FEDERATION STACK: ${site}"

    generate_site_cert "$site" "$host" "$private_ip"

    # Stage files.
    site_scp "$AGENT_BINARY" "$host" /tmp/federation-agent
    site_scp "$OPA_BINARY" "$host" /tmp/opa
    site_scp "$OPA_POLICY" "$host" /tmp/genomics.rego
    site_scp "$CERTS/$site/$site.crt" "$host" "/tmp/${site}.crt"
    site_scp "$CERTS/$site/$site.key" "$host" "/tmp/${site}.key"

    cp "$FED_CA_CERT" /tmp/federation-ca.crt
    chmod 0644 /tmp/federation-ca.crt
    site_scp /tmp/federation-ca.crt "$host" /tmp/ca.crt
    rm -f /tmp/federation-ca.crt

    site_ssh "$host" "bash -s -- '$site' '$host' '$private_ip' '$dataset'" <<'REMOTE'
set -Eeuo pipefail

SITE="$1"
MGMT_IP="$2"
PRIVATE_IP="$3"
DATASET="$4"

sudo apt-get update

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nginx \
    curl \
    jq \
    sqlite3 \
    iproute2 \
    iputils-ping \
    qemu-guest-agent

sudo systemctl enable --now qemu-guest-agent

sudo mkdir -p \
    /etc/federation-agent \
    /etc/federation-tls/ca \
    "/etc/federation-tls/${SITE}" \
    /etc/opa \
    /genomics/work/federation/logs \
    "/genomics/work/nextflow-${SITE}"

sudo install -o root -g root -m 0755 \
    /tmp/federation-agent \
    /usr/local/bin/federation-agent

sudo install -o root -g root -m 0755 \
    /tmp/opa \
    /usr/local/bin/opa

sudo install -o root -g root -m 0644 \
    /tmp/genomics.rego \
    /etc/opa/genomics.rego

sudo install -o root -g root -m 0644 \
    /tmp/ca.crt \
    /etc/federation-tls/ca/ca.crt

sudo install -o root -g root -m 0644 \
    "/tmp/${SITE}.crt" \
    "/etc/federation-tls/${SITE}/${SITE}.crt"

sudo install -o root -g root -m 0600 \
    "/tmp/${SITE}.key" \
    "/etc/federation-tls/${SITE}/${SITE}.key"

sudo tee /etc/systemd/system/opa.service >/dev/null <<'EOF'
[Unit]
Description=Open Policy Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/opa run \
  --server \
  --addr=127.0.0.1:8181 \
  /etc/opa/genomics.rego
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
sudo systemctl enable --now opa
sudo systemctl enable --now federation-agent

sleep 5

systemctl is-active opa
systemctl is-active federation-agent

curl -fsS http://127.0.0.1:8080/health | jq
REMOTE

    log "${site}: OPA + federation agent deployed"
}

# ============================================================
# NGINX mTLS
# ============================================================

configure_nginx() {
    local site="$1"
    local host="$2"

    section "NGINX MTLS: ${site}"

    # IMPORTANT: bind to the actual static management IP because
    # the 10.x private address is not automatically routed by vmbr0.
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

    access_log /var/log/nginx/federation-${SITE}-access.log;
    error_log /var/log/nginx/federation-${SITE}-error.log;

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

sudo ln -sf \
    "/etc/nginx/sites-available/federation-${SITE}" \
    "/etc/nginx/sites-enabled/federation-${SITE}"

sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx

ss -lnt | grep "${MGMT_IP}:8443"
REMOTE

    # Positive mTLS health test from Site A.
    curl -fsS \
        --cacert "$FED_CA_CERT" \
        --cert "$SITE_A_CLIENT_CERT" \
        --key "$SITE_A_CLIENT_KEY" \
        "https://${host}:8443/health" \
        | jq \
        | tee "$LOGS/${site}-mtls-health.json"

    # Negative test: no client certificate must be rejected.
    local no_mtls_code
    no_mtls_code="$(
        curl -s \
            -o /dev/null \
            -w '%{http_code}' \
            --cacert "$FED_CA_CERT" \
            "https://${host}:8443/health" \
            || true
    )"

    [ "$no_mtls_code" = "400" ] || [ "$no_mtls_code" = "403" ] \
        || die "${site}: expected no-mTLS rejection, got HTTP ${no_mtls_code}"

    log "${site}: mTLS positive + negative tests PASS"
}

# ============================================================
# DIRECT DDIL FOR NEW SITES
# ============================================================

set_new_site_ddil() {
    local host="$1"
    local profile="$2"
    local delay

    delay="$(ddil_delay_ms "$profile")"

    if [ "$delay" = "0" ]; then
        site_ssh "$host" \
            "sudo tc qdisc del dev eth0 root 2>/dev/null || true; tc qdisc show dev eth0"
    else
        site_ssh "$host" \
            "sudo tc qdisc replace dev eth0 root netem delay ${delay}ms; tc qdisc show dev eth0"
    fi
}

# ============================================================
# EXISTING SITE A<->B ROUTER DDIL
# ============================================================

set_router_ddil() {
    local profile="$1"

    router_ssh "$ROUTER_A" \
        "sudo -n /opt/ddil/set-latency-only.sh '${profile}'" \
        >/dev/null

    router_ssh "$ROUTER_B" \
        "sudo -n /opt/ddil/set-latency-only.sh '${profile}'" \
        >/dev/null
}

reset_all_ddil() {
    set_router_ddil baseline >/dev/null 2>&1 || true

    for ip in "$SITE_C_MGMT" "$SITE_D_MGMT" "$SITE_E_MGMT"; do
        if site_ssh "$ip" true >/dev/null 2>&1; then
            set_new_site_ddil "$ip" baseline >/dev/null 2>&1 || true
        fi
    done
}

# ============================================================
# CONTROL-PLANE TEST
# Measures mTLS + JWT + OPA on /raw-export.
# Expected HTTP result is 403 because raw export is forbidden.
# ============================================================

measure_control() {
    local site="$1"
    local target="$2"
    local profile="$3"
    local site_count="$4"

    local file="$DATA/control-sites${site_count}-${site}-${profile}.csv"

    echo "run,site_count,site,condition,http_code,total_ms" >"$file"

    for run in $(seq 1 "$CONTROL_REPETITIONS"); do
        local token result code seconds ms

        token="$("$TOKEN_SCRIPT")"

        result="$(
            curl -s \
                -o /dev/null \
                -w '%{http_code},%{time_total}' \
                --cacert "$FED_CA_CERT" \
                --cert "$SITE_A_CLIENT_CERT" \
                --key "$SITE_A_CLIENT_KEY" \
                -X POST \
                -H "Authorization: Bearer ${token}" \
                "https://${target}:8443/raw-export"
        )"

        code="${result%,*}"
        seconds="${result#*,}"

        ms="$(
            awk -v s="$seconds" 'BEGIN {printf "%.3f", s*1000}'
        )"

        echo "${run},${site_count},${site},${profile},${code},${ms}" \
            >>"$file"

        if [ "$code" != "403" ]; then
            echo "${site_count},${site},${profile},${run},HTTP_${code}" \
                >>"$FAILED_LOG"
        fi

        log "${site_count} sites | ${site} | ${profile} | run ${run}: ${ms} ms | HTTP ${code}"

        sleep 1
    done
}

# ============================================================
# SITE-COUNT EXPERIMENT
# ============================================================

run_site_count_experiment() {
    local count="$1"
    shift
    local entries=("$@")

    section "FEDERATION SIZE = ${count}"

    for profile in "${DDIL_PROFILES[@]}"; do
        # Site B uses inter-site routers.
        set_router_ddil "$profile"

        # Site C/D/E are currently on vmbr0 management network,
        # so shape their own egress on eth0.
        for entry in "${entries[@]}"; do
            local site="${entry%%:*}"
            local target="${entry##*:}"

            case "$site" in
                site-c|site-d|site-e)
                    set_new_site_ddil "$target" "$profile"
                    ;;
            esac
        done

        sleep 3

        for entry in "${entries[@]}"; do
            local site="${entry%%:*}"
            local target="${entry##*:}"

            # Record ping evidence for every target/profile.
            ping -c 10 -W 3 "$target" \
                >"$LOGS/ping-${count}sites-${site}-${profile}.txt" \
                2>&1 || true

            measure_control "$site" "$target" "$profile" "$count"
        done

        reset_all_ddil
        sleep 2
    done
}

# ============================================================
# SITE B RESOURCE SCALING
# ============================================================

wait_existing_site_b() {
    for i in $(seq 1 90); do
        if ssh \
            -i "$VM_SSH_PRIVATE_KEY" \
            -o BatchMode=yes \
            -o ConnectTimeout=5 \
            "fredrick@${SITE_B_MGMT}" \
            hostname >/dev/null 2>&1
        then
            return 0
        fi
        sleep 5
    done

    die "b-core did not return after resource change."
}

resize_site_b() {
    local profile="$1"
    local cores="$2"
    local memory="$3"

    section "SITE B RESOURCE PROFILE: ${profile}"

    pve_ssh "qm shutdown ${SITE_B_VMID} --timeout 120" || true

    # Ensure stopped before changing resources.
    for i in $(seq 1 30); do
        if pve_ssh "qm status ${SITE_B_VMID}" | grep -q 'status: stopped'; then
            break
        fi
        sleep 2
    done

    if ! pve_ssh "qm status ${SITE_B_VMID}" | grep -q 'status: stopped'; then
        log "Graceful shutdown timed out; forcing Site B VM stop."
        pve_ssh "qm stop ${SITE_B_VMID}"
    fi

    pve_ssh \
        "qm set ${SITE_B_VMID} \
         --cores ${cores} \
         --memory ${memory}"

    pve_ssh "qm start ${SITE_B_VMID}"

    wait_existing_site_b
    sleep 10

    ssh \
        -i "$VM_SSH_PRIVATE_KEY" \
        -o BatchMode=yes \
        "fredrick@${SITE_B_MGMT}" \
        'hostname; echo; nproc; free -h; echo; uptime' \
        >"$LOGS/site-b-resource-${profile}.txt"

    log "Site B now ${cores} vCPU / ${memory} MB"
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
            local token result code seconds ms

            token="$("$TOKEN_SCRIPT")"

            result="$(
                curl -s \
                    -o /dev/null \
                    -w '%{http_code},%{time_total}' \
                    --cacert "$FED_CA_CERT" \
                    --cert "$SITE_A_CLIENT_CERT" \
                    --key "$SITE_A_CLIENT_KEY" \
                    -X POST \
                    -H "Authorization: Bearer ${token}" \
                    "https://${SITE_B_PRIVATE}:8443/raw-export"
            )"

            code="${result%,*}"
            seconds="${result#*,}"
            ms="$(awk -v s="$seconds" 'BEGIN {printf "%.3f",s*1000}')"

            echo "${run},${profile},${cores},${memory},${code},${ms}" \
                >>"$out"

            log "resource=${profile} run=${run}: ${ms} ms HTTP ${code}"
        done
    done
}

restore_site_b() {
    section "RESTORING SITE B DEFAULT RESOURCES"

    resize_site_b "restored-default" "$DEFAULT_CORES" "$DEFAULT_MEMORY"
}

# ============================================================
# RESULTS
# ============================================================

generate_results() {
    section "GENERATING RESULTS + PLOTS"

    python3 - "$DATA" "$RESULTS" <<'PY'
import csv
import glob
import math
import os
import statistics
import sys

data_dir = sys.argv[1]
results_dir = sys.argv[2]

order = ["baseline", "mild", "moderate", "severe", "extreme"]

rows = []

for path in glob.glob(os.path.join(data_dir, "control-sites*.csv")):
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                rows.append({
                    "site_count": int(row["site_count"]),
                    "site": row["site"],
                    "condition": row["condition"],
                    "http_code": int(row["http_code"]),
                    "total_ms": float(row["total_ms"]),
                })
            except Exception:
                pass

groups = {}

for row in rows:
    key = (row["site_count"], row["site"], row["condition"])
    groups.setdefault(key, []).append(row)

summary_path = os.path.join(results_dir, "federation-scale-summary.csv")

with open(summary_path, "w", newline="") as f:
    fieldnames = [
        "site_count",
        "site",
        "condition",
        "n",
        "expected_403_percent",
        "mean_ms",
        "median_ms",
        "p95_ms",
        "p99_ms",
        "std_ms",
    ]

    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()

    for key in sorted(
        groups,
        key=lambda k: (k[0], k[1], order.index(k[2]) if k[2] in order else 99)
    ):
        group = groups[key]
        values = sorted(x["total_ms"] for x in group)

        def quantile(q):
            if not values:
                return float("nan")
            if len(values) == 1:
                return values[0]
            pos = (len(values) - 1) * q
            lo = math.floor(pos)
            hi = math.ceil(pos)
            if lo == hi:
                return values[lo]
            return values[lo] + (values[hi] - values[lo]) * (pos - lo)

        n = len(values)
        mean = statistics.mean(values)
        median = statistics.median(values)
        std = statistics.stdev(values) if n > 1 else 0.0
        expected = sum(1 for x in group if x["http_code"] == 403) / n * 100

        writer.writerow({
            "site_count": key[0],
            "site": key[1],
            "condition": key[2],
            "n": n,
            "expected_403_percent": round(expected, 2),
            "mean_ms": round(mean, 3),
            "median_ms": round(median, 3),
            "p95_ms": round(quantile(0.95), 3),
            "p99_ms": round(quantile(0.99), 3),
            "std_ms": round(std, 3),
        })

print(f"Wrote {summary_path}")
PY

    # Optional presentation plots if matplotlib is available.
    if python3 -c 'import matplotlib' >/dev/null 2>&1; then
        python3 - "$RESULTS/federation-scale-summary.csv" "$RESULTS" <<'PY'
import csv
import os
import sys
import matplotlib.pyplot as plt

summary_file = sys.argv[1]
results_dir = sys.argv[2]

with open(summary_file, newline="") as f:
    rows = list(csv.DictReader(f))

order = ["baseline", "mild", "moderate", "severe", "extreme"]

# One figure per federation size, using Site B when present.
site_counts = sorted({int(r["site_count"]) for r in rows})

for count in site_counts:
    subset = [
        r for r in rows
        if int(r["site_count"]) == count and r["site"] == "site-b"
    ]

    if not subset:
        continue

    subset.sort(key=lambda r: order.index(r["condition"]))

    x = [r["condition"] for r in subset]
    y = [float(r["mean_ms"]) for r in subset]

    plt.figure(figsize=(8, 5))
    plt.plot(x, y, marker="o")
    plt.xlabel("DDIL latency condition")
    plt.ylabel("Mean secured control-plane latency (ms)")
    plt.title(f"DDIL latency - {count}-site federation")
    plt.tight_layout()
    plt.savefig(
        os.path.join(results_dir, f"ddil-{count}-site-control-latency.png"),
        dpi=300
    )
    plt.close()

print("Plots generated.")
PY
    else
        log "matplotlib not installed; CSV summaries were generated, plots skipped."
    fi

    column -t -s, "$RESULTS/federation-scale-summary.csv" \
        | tee "$RESULTS/federation-scale-summary.txt"
}

# ============================================================
# CLEANUP
# ============================================================

cleanup() {
    log "Cleanup: resetting all DDIL conditions to baseline."
    reset_all_ddil || true
}

trap cleanup EXIT INT TERM

# ============================================================
# MAIN
# ============================================================

preflight
install_router_helpers

# ------------------------------------------------------------
# Existing 2-site baseline
# ------------------------------------------------------------
run_site_count_experiment \
    2 \
    "site-b:${SITE_B_PRIVATE}"

# ------------------------------------------------------------
# Add Site C
# ------------------------------------------------------------
create_vm "$SITE_C_VMID" "site-c" "$SITE_C_MGMT"
wait_for_ssh "$SITE_C_MGMT" "site-c"
install_and_verify_qemu_agent "$SITE_C_VMID" "$SITE_C_MGMT" "site-c"
deploy_site "site-c" "$SITE_C_MGMT" "$SITE_C_PRIVATE" "$SITE_C_DATASET"
configure_nginx "site-c" "$SITE_C_MGMT"

run_site_count_experiment \
    3 \
    "site-b:${SITE_B_PRIVATE}" \
    "site-c:${SITE_C_MGMT}"

# ------------------------------------------------------------
# Add Site D
# ------------------------------------------------------------
create_vm "$SITE_D_VMID" "site-d" "$SITE_D_MGMT"
wait_for_ssh "$SITE_D_MGMT" "site-d"
install_and_verify_qemu_agent "$SITE_D_VMID" "$SITE_D_MGMT" "site-d"
deploy_site "site-d" "$SITE_D_MGMT" "$SITE_D_PRIVATE" "$SITE_D_DATASET"
configure_nginx "site-d" "$SITE_D_MGMT"

run_site_count_experiment \
    4 \
    "site-b:${SITE_B_PRIVATE}" \
    "site-c:${SITE_C_MGMT}" \
    "site-d:${SITE_D_MGMT}"

# ------------------------------------------------------------
# Add Site E
# ------------------------------------------------------------
create_vm "$SITE_E_VMID" "site-e" "$SITE_E_MGMT"
wait_for_ssh "$SITE_E_MGMT" "site-e"
install_and_verify_qemu_agent "$SITE_E_VMID" "$SITE_E_MGMT" "site-e"
deploy_site "site-e" "$SITE_E_MGMT" "$SITE_E_PRIVATE" "$SITE_E_DATASET"
configure_nginx "site-e" "$SITE_E_MGMT"

run_site_count_experiment \
    5 \
    "site-b:${SITE_B_PRIVATE}" \
    "site-c:${SITE_C_MGMT}" \
    "site-d:${SITE_D_MGMT}" \
    "site-e:${SITE_E_MGMT}"

# ------------------------------------------------------------
# Resource scaling on existing Site B
# ------------------------------------------------------------
reset_all_ddil
run_resource_experiment

# ------------------------------------------------------------
# Restore + summarize
# ------------------------------------------------------------
restore_site_b
reset_all_ddil
generate_results

trap - EXIT INT TERM

section "EXPERIMENT COMPLETE"

echo
echo "New VMs:"
echo "  Site C: VMID ${SITE_C_VMID}, ${SITE_C_MGMT}/${VM_PREFIX}"
echo "  Site D: VMID ${SITE_D_VMID}, ${SITE_D_MGMT}/${VM_PREFIX}"
echo "  Site E: VMID ${SITE_E_VMID}, ${SITE_E_MGMT}/${VM_PREFIX}"

echo
echo "Raw data:"
echo "  ${DATA}"

echo
echo "Summary:"
echo "  ${RESULTS}/federation-scale-summary.csv"

echo
echo "Logs:"
echo "  ${LOGS}"

echo
echo "Failure log:"
echo "  ${FAILED_LOG}"

echo
echo "All DDIL shaping reset to baseline."
echo "Site B restored to ${DEFAULT_CORES} vCPU / ${DEFAULT_MEMORY} MB."

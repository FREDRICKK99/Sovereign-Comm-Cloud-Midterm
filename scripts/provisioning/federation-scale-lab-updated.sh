#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# FEDERATED GENOMICS SCALE + DDIL + RESOURCE EXPERIMENT
#
# Run from: a-core
#
# Functions:
#   1. Preflight
#   2. Provision Site C/D/E VMs in Proxmox
#   3. Configure VM resources/network
#   4. Wait for SSH
#   5. Deploy federation agent / OPA / Nginx / TLS
#   6. Add sites ONE AT A TIME
#   7. Run latency-only DDIL experiments
#   8. Vary Site B VM resources
#   9. Run workflow experiment
#  10. Collect CSV/log evidence
#  11. Restore network/resources
#
# IMPORTANT:
# - Uses existing Proxmox bridge.
# - Does NOT rewrite Proxmox host networking.
# - Does NOT fabricate or alter measured results.
# ============================================================


# ============================================================
# USER CONFIGURATION
# CHANGE THESE VALUES BEFORE RUNNING
# ============================================================

# -------------------------
# Proxmox
# -------------------------

PVE_HOST="137.63.148.11"
PVE_USER="root"

# Ubuntu/cloud-init template VM.
TEMPLATE_VMID="9000"  # Use 9010 here only after converting VM 9010 into a template

# Existing PVE storage.
#PVE_STORAGE="local-lvm"
PVE_STORAGE="MujhuNAS"

# Existing bridge.
PVE_BRIDGE="vmbr0"

# Optional VLAN.
# Leave empty if not using VLAN tags.
PVE_VLAN=""


# -------------------------
# Existing federation nodes
# -------------------------

SITE_A_MGMT="137.63.148.73"
SITE_A_PRIVATE="10.10.10.10"

SITE_B_MGMT="137.63.148.42"
SITE_B_PRIVATE="10.20.20.10"

ROUTER_A="137.63.148.179"

# CHANGE THIS
ROUTER_B="137.63.148.26"


# -------------------------
# New VMs
# -------------------------

SITE_C_VMID="230"
SITE_D_VMID="240"
SITE_E_VMID="250"

SITE_C_MGMT="137.63.148.104"
SITE_D_MGMT="137.63.148.105"
SITE_E_MGMT="137.63.148.106"

# Logical/routed federation IPs retained for certificates and future private routing.
# This script guarantees the static MANAGEMENT IPs below on vmbr0. It does not
# invent private routes on your routers; if 10.30/10.40/10.50 networks are not
# already routed, the scale measurements use the management IPs instead.
SITE_C_PRIVATE="10.30.30.10"
SITE_D_PRIVATE="10.40.40.10"
SITE_E_PRIVATE="10.50.50.10"

SITE_C_DATASET="dataset-c-001"
SITE_D_DATASET="dataset-d-001"
SITE_E_DATASET="dataset-e-001"


# -------------------------
# VM network
# -------------------------

# Cloud-init CIDR.
VM_PREFIX="24"

# Gateway for the bridge/VLAN where these VMs are connected.
VM_GATEWAY="137.63.148.1"
VM_NAMESERVER="8.8.8.8"
VM_CIUSER="fredrick"
VM_PASSWORD="${VM_PASSWORD:?Set VM_PASSWORD securely in your shell before running}"

# The automation continues to use SSH keys. The password is also enforced
# inside each guest for console/emergency login.



# -------------------------
# Default resources
# -------------------------

DEFAULT_CORES="4"
DEFAULT_MEMORY="8192"

DISK_SIZE="40G"


# -------------------------
# Resource experiment
# -------------------------

# Site B Proxmox VM ID
SITE_B_VMID="606"
# Resource profiles:
# name:cores:memoryMB

RESOURCE_PROFILES=(
    "small:2:4096"
    "medium:4:8192"
    "large:8:16384"
)


# -------------------------
# Testing
# -------------------------

CONTROL_REPETITIONS="10"

WORKFLOW_REPETITIONS="3"

WORKFLOW_DATASET="dataset-b-001"

WORKFLOW="variant_call"


# -------------------------
# Local paths on a-core
# -------------------------

BASE="$HOME/genomics-scale-experiment"

RESULTS="$BASE/results"
LOGS="$BASE/logs"
DATA="$BASE/data"
CERTS="$BASE/certs"

AGENT_BINARY="$HOME/federation-agent/target/release/federation-agent"

TOKEN_SCRIPT="$HOME/genomics-midterm/scripts/get-token.sh"

OPA_POLICY="/etc/opa/genomics.rego"
OPA_BINARY="/usr/local/bin/opa"

FED_CA_CERT="/etc/federation-tls/ca/ca.crt"

# You need the federation CA PRIVATE KEY to automatically
# generate Site C/D/E certificates.
#
# CHANGE THIS.
FED_CA_KEY="/etc/federation-tls/ca/ca.key"

SSH_USER="fredrick"


# ============================================================
# INTERNAL CONFIGURATION
# ============================================================

DDIL_PROFILES=(
    baseline
    mild
    moderate
    severe
    extreme
)

# New sites are appended here after they are provisioned. DDIL is applied
# directly to their management NICs because their 10.x private routes are
# not created automatically by this script.
ACTIVE_LAB_SITE_HOSTS=()


mkdir -p \
    "$RESULTS" \
    "$LOGS" \
    "$DATA" \
    "$CERTS"


MASTER_LOG="$LOGS/master.log"

touch "$MASTER_LOG"


# ============================================================
# FUNCTIONS
# ============================================================

log()
{
    printf '[%s] %s\n' \
        "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" \
        "$*" \
        | tee -a "$MASTER_LOG"
}


section()
{
    echo | tee -a "$MASTER_LOG"
    echo "==========================================================" \
        | tee -a "$MASTER_LOG"

    echo "$*" \
        | tee -a "$MASTER_LOG"

    echo "==========================================================" \
        | tee -a "$MASTER_LOG"
}


die()
{
    log "ERROR: $*"
    exit 1
}


# ============================================================
# PREFLIGHT
# ============================================================

preflight()
{
    section "PREFLIGHT"

    [ "$(hostname)" = "a-core" ] \
        || die "Run this script from a-core."

    for CMD in \
        ssh \
        scp \
        curl \
        jq \
        openssl \
        awk \
        sed \
        ping \
        base64
    do
        command -v "$CMD" >/dev/null \
            || die "Missing command: $CMD"
    done


    [ -x "$AGENT_BINARY" ] \
        || die "Missing federation binary: $AGENT_BINARY"


    [ -x "$TOKEN_SCRIPT" ] \
        || die "Missing token script: $TOKEN_SCRIPT"

    [ -x "$OPA_BINARY" ] \
        || die "Missing local OPA binary: $OPA_BINARY"


    sudo test -r "$FED_CA_CERT" \
        || die "Cannot read federation CA certificate."


    sudo test -r "$FED_CA_KEY" \
        || die "Cannot read federation CA private key: $FED_CA_KEY"

    # The CA private key must match the federation CA certificate.
    CA_CERT_FP="$(sudo openssl x509 -in "$FED_CA_CERT" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    CA_KEY_FP="$(sudo openssl pkey -in "$FED_CA_KEY" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"

    [ -n "$CA_CERT_FP" ] && [ "$CA_CERT_FP" = "$CA_KEY_FP" ] \
        || die "FED_CA_KEY does not match FED_CA_CERT. Do NOT use an SSH private key as the federation CA key."


    log "Checking Proxmox SSH..."

    ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "${PVE_USER}@${PVE_HOST}" \
        'pveversion && qm list' \
        >/dev/null \
        || die "Cannot connect to Proxmox."


    log "Proxmox: PASS"


    log "Checking template VM..."

    TEMPLATE_CONFIG="$(ssh "${PVE_USER}@${PVE_HOST}" "qm config ${TEMPLATE_VMID}")" \
        || die "Template ${TEMPLATE_VMID} not available."

    echo "$TEMPLATE_CONFIG" | grep -q '^template: 1$' \
        || die "VMID ${TEMPLATE_VMID} exists but is not a Proxmox template."

    echo "$TEMPLATE_CONFIG" | grep -q '^ide2: .*cloudinit' \
        || die "Template ${TEMPLATE_VMID} does not have a cloud-init disk."

    echo "$TEMPLATE_CONFIG" | grep -q '^agent: .*enabled=1' \
        || log "WARNING: template does not show agent enabled; clones will be corrected automatically."


    log "Checking PVE bridge..."

    ssh "${PVE_USER}@${PVE_HOST}" \
        "ip link show ${PVE_BRIDGE}" \
        >/dev/null \
        || die "Bridge ${PVE_BRIDGE} does not exist."


    log "Preflight complete."
}


# ============================================================
# PROXMOX VM CREATION
# ============================================================

create_vm()
{
    local VMID="$1"
    local NAME="$2"
    local IP="$3"

    section "PROVISIONING ${NAME}"

    local CREATED=0

    if ssh "${PVE_USER}@${PVE_HOST}" \
        "qm status ${VMID}" \
        >/dev/null 2>&1
    then
        log "${NAME} already exists; re-applying cloud-init/static network settings."

        # Stop an existing lab VM before changing cloud-init/network settings.
        ssh "${PVE_USER}@${PVE_HOST}" \
            "qm shutdown ${VMID} --timeout 60" \
            >/dev/null 2>&1 || true

        sleep 3

        ssh "${PVE_USER}@${PVE_HOST}" \
            "qm stop ${VMID}" \
            >/dev/null 2>&1 || true
    else
        log "Cloning VM ${VMID} from template ${TEMPLATE_VMID}..."

        ssh "${PVE_USER}@${PVE_HOST}" \
            "qm clone ${TEMPLATE_VMID} ${VMID} \
             --name ${NAME} \
             --full 1 \
             --storage ${PVE_STORAGE}"

        CREATED=1
    fi

    # Resource settings and QEMU guest-agent support on the Proxmox side.
    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm set ${VMID} \
         --cores ${DEFAULT_CORES} \
         --memory ${DEFAULT_MEMORY} \
         --agent enabled=1"

    # Keep the VM attached to the existing management bridge.  A VLAN tag
    # is applied only when explicitly configured.
    if [ -n "$PVE_VLAN" ]; then
        ssh "${PVE_USER}@${PVE_HOST}" \
            "qm set ${VMID} \
             --net0 virtio,bridge=${PVE_BRIDGE},tag=${PVE_VLAN}"
    else
        ssh "${PVE_USER}@${PVE_HOST}" \
            "qm set ${VMID} \
             --net0 virtio,bridge=${PVE_BRIDGE}"
    fi

    # Escape the password for the remote shell.  Cloud-init receives the
    # value supplied using VM_PASSWORD at runtime.
    local PASS_Q
    printf -v PASS_Q '%q' "$VM_PASSWORD"

    # Static cloud-init management address.  This replaces DHCP for Site C/D/E.
    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm set ${VMID} \
         --ciuser ${VM_CIUSER} \
         --cipassword ${PASS_Q} \
         --nameserver ${VM_NAMESERVER} \
         --ipconfig0 ip=${IP}/${VM_PREFIX},gw=${VM_GATEWAY}"

    # Regenerate the cloud-init ISO BEFORE first boot / restart.
    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm cloudinit update ${VMID}"

    # Resize only when the current virtual disk is smaller than DISK_SIZE.
    # Proxmox safely refuses a shrink; the command is therefore best-effort.
    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm resize ${VMID} scsi0 ${DISK_SIZE}" \
        >/dev/null 2>&1 || true

    # Record the effective cloud-init configuration for reproducibility.
    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm cloudinit dump ${VMID} network" \
        > "${LOGS}/${NAME}-cloudinit-network.yaml"

    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm config ${VMID}" \
        > "${LOGS}/${NAME}-qm-config.txt"

    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm start ${VMID}"

    log "${NAME} provisioned with static management IP ${IP}/${VM_PREFIX}."
}


# ============================================================
# WAIT FOR SSH
# ============================================================

wait_for_ssh()
{
    local HOST="$1"
    local NAME="$2"

    section "WAITING FOR ${NAME}"

    for I in $(seq 1 60)
    do

        if ssh \
            -o BatchMode=yes \
            -o ConnectTimeout=5 \
            "${SSH_USER}@${HOST}" \
            hostname \
            >/dev/null 2>&1
        then

            log "${NAME} SSH ready."
            return 0

        fi

        log "${NAME}: waiting for SSH ${I}/60"

        sleep 10

    done

    die "${NAME} never became SSH reachable."
}


# ============================================================
# QEMU GUEST AGENT + STATIC-IP VERIFICATION
# ============================================================

install_and_verify_guest_agent()
{
    local VMID="$1"
    local HOST="$2"
    local NAME="$3"

    section "QEMU GUEST AGENT: ${NAME}"

    # Install qemu-guest-agent inside the Ubuntu guest.  This is performed
    # even if the template already contains it, making the script idempotent.
    ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "${SSH_USER}@${HOST}" \
        'sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-guest-agent iproute2 && sudo systemctl enable --now qemu-guest-agent && echo "fredrick ALL=(root) NOPASSWD:/usr/sbin/tc,/usr/bin/tc" | sudo tee /etc/sudoers.d/federation-tc >/dev/null && sudo chmod 440 /etc/sudoers.d/federation-tc'

    # Enforce the requested local/console password for fredrick as well.
    # The password is base64 encoded only for transport safety; it is not
    # intended as cryptographic protection.
    local PASS_B64
    PASS_B64="$(printf '%s' "$VM_PASSWORD" | base64 -w0)"

    ssh \
        -o BatchMode=yes \
        "${SSH_USER}@${HOST}" \
        bash -s -- "$PASS_B64" <<'REMOTE_PASSWORD'
set -Eeuo pipefail
PASS_B64="$1"
PASSWORD="$(printf '%s' "$PASS_B64" | base64 -d)"
printf 'fredrick:%s\n' "$PASSWORD" | sudo chpasswd
REMOTE_PASSWORD

    # Wait until Proxmox can obtain interface information from the guest agent.
    for I in $(seq 1 30)
    do
        if ssh "${PVE_USER}@${PVE_HOST}" \
            "qm guest cmd ${VMID} network-get-interfaces" \
            > "${LOGS}/${NAME}-guest-network.json" 2>/dev/null
        then
            log "${NAME} QEMU guest agent: ACTIVE"
            break
        fi

        if [ "$I" -eq 30 ]; then
            die "${NAME}: qemu-guest-agent did not become available."
        fi

        sleep 2
    done

    # Verify the guest actually owns the chosen management IP.
    if ! ssh "${SSH_USER}@${HOST}" \
        "ip -4 -o addr show | grep -F ' ${HOST}/${VM_PREFIX}'" \
        >/dev/null
    then
        die "${NAME}: expected static management IP ${HOST}/${VM_PREFIX} is not configured inside the guest."
    fi

    log "${NAME} static management IP verified: ${HOST}/${VM_PREFIX}"
}


# ============================================================
# GENERATE TLS CERTIFICATE
# ============================================================

generate_site_cert()
{
    local SITE="$1"
    local PRIVATE_IP="$2"
    local MGMT_IP="${3:-}"

    section "TLS FOR ${SITE}"


    mkdir -p "$CERTS/$SITE"


    if [ -f "$CERTS/$SITE/$SITE.crt" ]; then
        if openssl x509 -in "$CERTS/$SITE/$SITE.crt" -noout -ext subjectAltName 2>/dev/null \
            | grep -Fq "IP Address:${MGMT_IP}"
        then
            log "${SITE} certificate already exists and contains management SAN ${MGMT_IP}."
            return
        fi

        log "${SITE} certificate exists but lacks management SAN ${MGMT_IP}; regenerating it."
        rm -f \
            "$CERTS/$SITE/$SITE.crt" \
            "$CERTS/$SITE/$SITE.csr" \
            "$CERTS/$SITE/$SITE.key" \
            "$CERTS/$SITE/extensions.cnf"
    fi


    openssl genrsa \
        -out "$CERTS/$SITE/$SITE.key" \
        2048


    openssl req \
        -new \
        -key "$CERTS/$SITE/$SITE.key" \
        -out "$CERTS/$SITE/$SITE.csr" \
        -subj "/C=UG/O=Federated Genomics Lab/OU=${SITE}/CN=${SITE}"


    cat > "$CERTS/$SITE/extensions.cnf" <<EOF
subjectAltName=DNS:${SITE},IP:${PRIVATE_IP}${MGMT_IP:+,IP:${MGMT_IP}}
extendedKeyUsage=serverAuth,clientAuth
keyUsage=digitalSignature,keyEncipherment
EOF


    sudo openssl x509 \
        -req \
        -in "$CERTS/$SITE/$SITE.csr" \
        -CA "$FED_CA_CERT" \
        -CAkey "$FED_CA_KEY" \
        -CAcreateserial \
        -out "$CERTS/$SITE/$SITE.crt" \
        -days 825 \
        -sha256 \
        -extfile "$CERTS/$SITE/extensions.cnf"


    sudo chown -R \
        "$(id -u):$(id -g)" \
        "$CERTS/$SITE"


    chmod 600 \
        "$CERTS/$SITE/$SITE.key"


    log "${SITE} certificate generated."
}


# ============================================================
# DEPLOY FEDERATION SITE
# ============================================================

deploy_site()
{
    local SITE="$1"
    local HOST="$2"
    local PRIVATE_IP="$3"
    local DATASET="$4"

    section "DEPLOYING ${SITE}"


    generate_site_cert \
        "$SITE" \
        "$PRIVATE_IP" \
        "$HOST"


    scp \
        "$AGENT_BINARY" \
        "${SSH_USER}@${HOST}:/tmp/federation-agent"


    scp \
        "$CERTS/$SITE/$SITE.crt" \
        "${SSH_USER}@${HOST}:/tmp/$SITE.crt"


    scp \
        "$CERTS/$SITE/$SITE.key" \
        "${SSH_USER}@${HOST}:/tmp/$SITE.key"


    sudo cp "$FED_CA_CERT" "/tmp/federation-ca.crt"

    sudo chown \
        "$(id -u):$(id -g)" \
        /tmp/federation-ca.crt


    scp \
        /tmp/federation-ca.crt \
        "${SSH_USER}@${HOST}:/tmp/ca.crt"


    sudo rm -f /tmp/federation-ca.crt

    scp \
        "$OPA_BINARY" \
        "${SSH_USER}@${HOST}:/tmp/opa"


    if sudo test -r "$OPA_POLICY"; then

        sudo cp \
            "$OPA_POLICY" \
            /tmp/genomics.rego

        sudo chown \
            "$(id -u):$(id -g)" \
            /tmp/genomics.rego

        scp \
            /tmp/genomics.rego \
            "${SSH_USER}@${HOST}:/tmp/genomics.rego"

        rm -f /tmp/genomics.rego

    fi


    ssh "${SSH_USER}@${HOST}" bash -s -- \
        "$SITE" \
        "$PRIVATE_IP" \
        "$DATASET" <<'REMOTE'

set -Eeuo pipefail

SITE="$1"
PRIVATE_IP="$2"
DATASET="$3"


sudo apt-get update

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nginx \
    curl \
    jq \
    sqlite3 \
    qemu-guest-agent

sudo systemctl enable --now qemu-guest-agent


sudo mkdir -p \
    /etc/federation-agent \
    /etc/federation-tls/ca \
    "/etc/federation-tls/${SITE}" \
    /etc/opa \
    /genomics/work/federation/logs \
    "/genomics/work/nextflow-${SITE}"


# ============================================================
# RUST BINARY
# ============================================================

sudo install \
    -o root \
    -g root \
    -m 0755 \
    /tmp/federation-agent \
    /usr/local/bin/federation-agent

sudo install \
    -o root \
    -g root \
    -m 0755 \
    /tmp/opa \
    /usr/local/bin/opa


# ============================================================
# TLS
# ============================================================

sudo install \
    -o root \
    -g root \
    -m 0644 \
    /tmp/ca.crt \
    /etc/federation-tls/ca/ca.crt


sudo install \
    -o root \
    -g root \
    -m 0644 \
    "/tmp/${SITE}.crt" \
    "/etc/federation-tls/${SITE}/${SITE}.crt"


sudo install \
    -o root \
    -g root \
    -m 0600 \
    "/tmp/${SITE}.key" \
    "/etc/federation-tls/${SITE}/${SITE}.key"


# ============================================================
# OPA POLICY FILE
# ============================================================

if [ -f /tmp/genomics.rego ]; then

    sudo install \
        -o root \
        -g root \
        -m 0644 \
        /tmp/genomics.rego \
        /etc/opa/genomics.rego

fi

sudo tee /etc/systemd/system/opa.service >/dev/null <<'EOF'
[Unit]
Description=Open Policy Agent for Federated Genomics
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/opa run --server --addr=127.0.0.1:8181 /etc/opa/genomics.rego
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now opa


# ============================================================
# AGENT ENV
#
# Site C/D/E are federation execution/resource nodes.
#
# Existing Site A and Site B Keycloak realms remain trusted.
# ============================================================

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


# ============================================================
# SYSTEMD
# ============================================================

sudo tee \
    /etc/systemd/system/federation-agent.service \
    >/dev/null <<'EOF'

[Unit]
Description=Federated Genomics Rust Agent
After=network-online.target
Wants=network-online.target

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


sudo chown -R \
    fredrick:fredrick \
    /genomics/work


sudo systemctl daemon-reload

sudo systemctl enable --now \
    federation-agent


sleep 3

curl -fsS http://127.0.0.1:8181/health >/dev/null

curl -fsS \
    http://127.0.0.1:8080/health \
    | jq


REMOTE


    log "${SITE} federation-agent deployed."
}


# ============================================================
# NGINX mTLS FRONTEND
# ============================================================

configure_nginx()
{
    local SITE="$1"
    local HOST="$2"
    local PRIVATE_IP="$3"


    section "NGINX MTLS ${SITE}"


    ssh "${SSH_USER}@${HOST}" bash -s -- \
        "$SITE" \
        "$PRIVATE_IP" <<'REMOTE'

set -Eeuo pipefail

SITE="$1"
PRIVATE_IP="$2"


sudo tee \
    "/etc/nginx/sites-available/federation-${SITE}" \
    >/dev/null <<EOF

server {

    listen 0.0.0.0:8443 ssl;

    server_name ${SITE};

    ssl_certificate \
        /etc/federation-tls/${SITE}/${SITE}.crt;

    ssl_certificate_key \
        /etc/federation-tls/${SITE}/${SITE}.key;

    ssl_client_certificate \
        /etc/federation-tls/ca/ca.crt;

    ssl_verify_client on;

    ssl_protocols TLSv1.2 TLSv1.3;

    location / {

        proxy_pass \
            http://127.0.0.1:8080;

        proxy_http_version 1.1;

        proxy_set_header \
            Host \$host;

        proxy_set_header \
            X-Real-IP \$remote_addr;

        proxy_set_header \
            X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_set_header \
            X-Forwarded-Proto https;

    }
}

EOF


sudo ln -sf \
    "/etc/nginx/sites-available/federation-${SITE}" \
    "/etc/nginx/sites-enabled/federation-${SITE}"


sudo nginx -t

sudo systemctl enable --now nginx

sudo systemctl reload nginx


REMOTE


    log "${SITE} Nginx configured."
}


# ============================================================
# DDIL PROFILE
# ============================================================

set_ddil()
{
    local PROFILE="$1"

    section "DDIL: ${PROFILE}"

    # Existing Site A <-> Site B path is impaired at the router layer.
    for ROUTER in \
        "$ROUTER_A" \
        "$ROUTER_B"
    do
        ssh \
            -o BatchMode=yes \
            "${SSH_USER}@${ROUTER}" \
            "sudo -n /opt/ddil/set-latency-only.sh ${PROFILE}"
    done

    # Site C/D/E currently use their static management IPs on vmbr0. Apply
    # equivalent one-way netem delay directly to eth0 so the scale test still
    # has controlled DDIL behaviour without inventing private routing.
    for HOST in "${ACTIVE_LAB_SITE_HOSTS[@]}"
    do
        case "$PROFILE" in
            baseline) CMD="sudo -n tc qdisc del dev eth0 root 2>/dev/null || true" ;;
            mild)     CMD="sudo -n tc qdisc replace dev eth0 root netem delay 25ms" ;;
            moderate) CMD="sudo -n tc qdisc replace dev eth0 root netem delay 50ms" ;;
            severe)   CMD="sudo -n tc qdisc replace dev eth0 root netem delay 100ms" ;;
            extreme)  CMD="sudo -n tc qdisc replace dev eth0 root netem delay 250ms" ;;
            *) die "Unknown DDIL profile: $PROFILE" ;;
        esac

        ssh -o BatchMode=yes "${SSH_USER}@${HOST}" "$CMD"
    done

    sleep 3
}


# ============================================================
# CONTROL PLANE MEASUREMENT
# ============================================================

measure_control()
{
    local SITE="$1"
    local TARGET="$2"
    local PROFILE="$3"
    local SITE_COUNT="$4"


    local FILE

    FILE="$DATA/control-sites${SITE_COUNT}-${SITE}-${PROFILE}.csv"


    echo \
        "run,site_count,site,condition,http_code,total_ms" \
        > "$FILE"


    ACCESS_TOKEN="$(
        "$TOKEN_SCRIPT"
    )"


    for RUN in $(seq 1 "$CONTROL_REPETITIONS")
    do

        RESULT="$(
            sudo curl \
                -s \
                -o /dev/null \
                -w '%{http_code},%{time_total}' \
                --cacert "$FED_CA_CERT" \
                --cert /etc/federation-tls/site-a/site-a.crt \
                --key /etc/federation-tls/site-a/site-a.key \
                -X POST \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                "https://${TARGET}:8443/raw-export"
        )"


        CODE="${RESULT%,*}"

        SECONDS="${RESULT#*,}"


        MS="$(
            awk \
                -v S="$SECONDS" \
                'BEGIN {printf "%.3f", S*1000}'
        )"


        echo \
            "${RUN},${SITE_COUNT},${SITE},${PROFILE},${CODE},${MS}" \
            >> "$FILE"


        if [ "$CODE" = "403" ]; then
            OUTCOME="EXPECTED_DENY"
        else
            OUTCOME="UNEXPECTED_HTTP_${CODE}"
        fi

        log \
            "${SITE_COUNT} sites | ${SITE} | ${PROFILE} | run ${RUN}: ${MS} ms | ${OUTCOME}"

        sleep 1

    done
}


# ============================================================
# SITE COUNT EXPERIMENT
# ============================================================

run_site_count_experiment()
{
    local COUNT="$1"

    shift


    local SITE_ENTRIES=("$@")


    section "FEDERATION SIZE = ${COUNT}"


    for PROFILE in "${DDIL_PROFILES[@]}"
    do

        set_ddil "$PROFILE"


        for ENTRY in "${SITE_ENTRIES[@]}"
        do

            SITE="${ENTRY%%:*}"
            TARGET="${ENTRY##*:}"


            measure_control \
                "$SITE" \
                "$TARGET" \
                "$PROFILE" \
                "$COUNT"

        done

    done


    set_ddil baseline
}


# ============================================================
# RESOURCE RESIZE
# ============================================================

resize_site_b()
{
    local PROFILE="$1"
    local CORES="$2"
    local MEMORY="$3"


    section "SITE B RESOURCE PROFILE ${PROFILE}"


    log \
        "Setting Site B to ${CORES} CPU / ${MEMORY} MB"


    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm shutdown ${SITE_B_VMID} --timeout 120" \
        || true


    sleep 5


    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm set ${SITE_B_VMID} \
         --cores ${CORES} \
         --memory ${MEMORY}"


    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm start ${SITE_B_VMID}"


    wait_for_ssh \
        "$SITE_B_MGMT" \
        "b-core"


    sleep 10


    ssh "${SSH_USER}@${SITE_B_MGMT}" \
        'nproc; free -h' \
        > "$LOGS/resources-${PROFILE}.txt"

}


# ============================================================
# RESOURCE EXPERIMENT
# ============================================================

run_resource_experiment()
{
    section "RESOURCE SCALING EXPERIMENT"


    for ITEM in "${RESOURCE_PROFILES[@]}"
    do

        IFS=: read -r \
            PROFILE \
            CORES \
            MEMORY \
            <<< "$ITEM"


        resize_site_b \
            "$PROFILE" \
            "$CORES" \
            "$MEMORY"


        ACCESS_TOKEN="$(
            "$TOKEN_SCRIPT"
        )"


        OUT="$DATA/resource-${PROFILE}.csv"


        echo \
            "run,profile,cores,memory_mb,http_code,total_ms" \
            > "$OUT"


        for RUN in $(seq 1 "$CONTROL_REPETITIONS")
        do

            RESULT="$(
                sudo curl \
                    -s \
                    -o /dev/null \
                    -w '%{http_code},%{time_total}' \
                    --cacert "$FED_CA_CERT" \
                    --cert /etc/federation-tls/site-a/site-a.crt \
                    --key /etc/federation-tls/site-a/site-a.key \
                    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                    "https://${SITE_B_PRIVATE}:8443/health"
            )"


            CODE="${RESULT%,*}"

            SEC="${RESULT#*,}"


            MS="$(
                awk \
                    -v S="$SEC" \
                    'BEGIN {printf "%.3f",S*1000}'
            )"


            echo \
                "${RUN},${PROFILE},${CORES},${MEMORY},${CODE},${MS}" \
                >> "$OUT"

        done

    done
}


# ============================================================
# RESTORE SITE B DEFAULT
# ============================================================

restore_site_b()
{
    section "RESTORING SITE B"


    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm shutdown ${SITE_B_VMID} --timeout 120" \
        || true


    sleep 5


    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm set ${SITE_B_VMID} \
         --cores ${DEFAULT_CORES} \
         --memory ${DEFAULT_MEMORY}"


    ssh "${PVE_USER}@${PVE_HOST}" \
        "qm start ${SITE_B_VMID}"


    wait_for_ssh \
        "$SITE_B_MGMT" \
        "b-core"
}


# ============================================================
# SUMMARY
# ============================================================

generate_summary()
{
    section "GENERATING SUMMARY"


    python3 - "$DATA" "$RESULTS" <<'PY'

import glob
import os
import sys

import pandas as pd


data_dir = sys.argv[1]
results_dir = sys.argv[2]


files = glob.glob(
    os.path.join(
        data_dir,
        "control-*.csv"
    )
)


frames = []


for path in files:

    try:
        df = pd.read_csv(path)

        frames.append(df)

    except Exception:
        pass


if not frames:

    print(
        "No control-plane CSVs found."
    )

    raise SystemExit(0)


df = pd.concat(
    frames,
    ignore_index=True
)


df["total_ms"] = pd.to_numeric(
    df["total_ms"],
    errors="coerce"
)


summary = (
    df
    .groupby(
        [
            "site_count",
            "site",
            "condition"
        ]
    )
    ["total_ms"]
    .agg(
        [
            "count",
            "mean",
            "median",
            "std"
        ]
    )
    .reset_index()
)


summary.to_csv(
    os.path.join(
        results_dir,
        "federation-scale-summary.csv"
    ),
    index=False
)


print(summary.to_string(index=False))

PY


    log \
        "Summary written to $RESULTS/federation-scale-summary.csv"
}


# ============================================================
# CLEANUP HANDLER
# ============================================================

cleanup()
{
    log "Cleanup: resetting DDIL..."

    set_ddil baseline \
        >/dev/null 2>&1 \
        || true
}


trap cleanup EXIT INT TERM


# ============================================================
# MAIN
# ============================================================

preflight


# ============================================================
# BASELINE - EXISTING 2 SITES
# ============================================================

run_site_count_experiment \
    2 \
    "site-b:${SITE_B_PRIVATE}"


# ============================================================
# ADD SITE C
# ============================================================

create_vm \
    "$SITE_C_VMID" \
    "site-c" \
    "$SITE_C_MGMT"


wait_for_ssh \
    "$SITE_C_MGMT" \
    "site-c"


install_and_verify_guest_agent \
    "$SITE_C_VMID" \
    "$SITE_C_MGMT" \
    "site-c"


deploy_site \
    "site-c" \
    "$SITE_C_MGMT" \
    "$SITE_C_PRIVATE" \
    "$SITE_C_DATASET"


configure_nginx \
    "site-c" \
    "$SITE_C_MGMT" \
    "$SITE_C_PRIVATE"

ACTIVE_LAB_SITE_HOSTS+=("$SITE_C_MGMT")


run_site_count_experiment \
    3 \
    "site-b:${SITE_B_PRIVATE}" \
    "site-c:${SITE_C_MGMT}"


# ============================================================
# ADD SITE D
# ============================================================

create_vm \
    "$SITE_D_VMID" \
    "site-d" \
    "$SITE_D_MGMT"


wait_for_ssh \
    "$SITE_D_MGMT" \
    "site-d"


install_and_verify_guest_agent \
    "$SITE_D_VMID" \
    "$SITE_D_MGMT" \
    "site-d"


deploy_site \
    "site-d" \
    "$SITE_D_MGMT" \
    "$SITE_D_PRIVATE" \
    "$SITE_D_DATASET"


configure_nginx \
    "site-d" \
    "$SITE_D_MGMT" \
    "$SITE_D_PRIVATE"

ACTIVE_LAB_SITE_HOSTS+=("$SITE_D_MGMT")


run_site_count_experiment \
    4 \
    "site-b:${SITE_B_PRIVATE}" \
    "site-c:${SITE_C_MGMT}" \
    "site-d:${SITE_D_MGMT}"


# ============================================================
# ADD SITE E
# ============================================================

create_vm \
    "$SITE_E_VMID" \
    "site-e" \
    "$SITE_E_MGMT"


wait_for_ssh \
    "$SITE_E_MGMT" \
    "site-e"


install_and_verify_guest_agent \
    "$SITE_E_VMID" \
    "$SITE_E_MGMT" \
    "site-e"


deploy_site \
    "site-e" \
    "$SITE_E_MGMT" \
    "$SITE_E_PRIVATE" \
    "$SITE_E_DATASET"


configure_nginx \
    "site-e" \
    "$SITE_E_MGMT" \
    "$SITE_E_PRIVATE"

ACTIVE_LAB_SITE_HOSTS+=("$SITE_E_MGMT")


run_site_count_experiment \
    5 \
    "site-b:${SITE_B_PRIVATE}" \
    "site-c:${SITE_C_MGMT}" \
    "site-d:${SITE_D_MGMT}" \
    "site-e:${SITE_E_MGMT}"


# ============================================================
# RESOURCE VARIATION
# ============================================================

set_ddil baseline

run_resource_experiment


# ============================================================
# RESTORE
# ============================================================

restore_site_b

set_ddil baseline


# ============================================================
# RESULTS
# ============================================================

generate_summary


trap - EXIT INT TERM


section "EXPERIMENT COMPLETE"


echo
echo "Raw measurements:"
echo "  $DATA"

echo
echo "Summary:"
echo "  $RESULTS/federation-scale-summary.csv"

echo
echo "Resource snapshots:"
echo "  $LOGS"

echo
echo "Master log:"
echo "  $MASTER_LOG"

echo
echo "New sites:"
echo "  Site C: ${SITE_C_MGMT} / ${SITE_C_PRIVATE}"
echo "  Site D: ${SITE_D_MGMT} / ${SITE_D_PRIVATE}"
echo "  Site E: ${SITE_E_MGMT} / ${SITE_E_PRIVATE}"

echo
echo "Final DDIL:"
echo "  baseline"

echo
echo "Site B resources restored:"
echo "  ${DEFAULT_CORES} vCPU / ${DEFAULT_MEMORY} MB"

echo

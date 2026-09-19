#!/bin/bash
# =============================================================
# SOC Lab Class 02 - Ubuntu Splunk Universal Forwarder Setup
# Target: srv-linux-01 (Ubuntu 22.04 LTS) -> Win 11 Splunk Enterprise
# =============================================================

set -u
set -o pipefail

# ---------- CONFIG ----------
SPLUNK_SERVER_IP="192.168.10.1"
SPLUNK_PORT="9997"
UF_HOME="/opt/splunkforwarder"
UF_EXE="$UF_HOME/bin/splunk"
WORK_DIR="/tmp/soc_uf"
ADMIN_USER="admin"
ADMIN_PASS="P@ssw0rd2026!"
SPLUNK_HOSTNAME="srv-linux-01"

# Log file locations on Ubuntu
LOG_AUTH="/var/log/auth.log"
LOG_SYSLOG="/var/log/syslog"
LOG_KERN="/var/log/kern.log"
LOG_AUDIT="/var/log/audit/audit.log"
LOG_ATTACK="/home/socadmin/linux_attacks_sample.log"

# ---------- COLORS ----------
GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"

say()  { echo -e "${CYAN}[*]${RESET} $1"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
err()  { echo -e "${RED}[ERR]${RESET} $1"; }
step() {
    echo ""
    echo -e "${BOLD}${CYAN}=============================================================${RESET}"
    echo -e "${BOLD}${CYAN}  $1${RESET}"
    echo -e "${BOLD}${CYAN}=============================================================${RESET}"
}

# ---------- PHASE 0: SANITY ----------
step "Phase 0: Sanity checks"

if [ "$EUID" -ne 0 ]; then
    err "This script must run as root."
    echo "    Run: sudo bash $0"
    exit 1
fi
ok "Running as root."

if ! command -v apt-get >/dev/null 2>&1; then
    err "apt-get not found. This script requires Debian/Ubuntu."
    exit 1
fi
ok "Debian/Ubuntu confirmed."

# Show current IP
CURRENT_IP=$(hostname -I | awk '{print $1}')
say "Current IP: $CURRENT_IP"
say "Target Splunk server: ${SPLUNK_SERVER_IP}:${SPLUNK_PORT}"

# ---------- PHASE 1: TCP TEST ----------
step "Phase 1: Test TCP to Splunk server"

export DEBIAN_FRONTEND=noninteractive
apt-get install -y netcat-openbsd >/dev/null 2>&1 || true

if nc -z -w 3 "${SPLUNK_SERVER_IP}" "${SPLUNK_PORT}" 2>/dev/null; then
    ok "TCP ${SPLUNK_SERVER_IP}:${SPLUNK_PORT} is reachable."
else
    warn "TCP ${SPLUNK_SERVER_IP}:${SPLUNK_PORT} is NOT reachable."
    warn "Continuing anyway, but logs won't flow until this is fixed."
    warn "Fix on Win 11: netstat -ano | findstr :9997"
    warn "              New-NetFirewallRule -DisplayName 'Splunk 9997' -Direction Inbound -Protocol TCP -LocalPort 9997 -Action Allow"
    echo ""
    read -p "Continue anyway? [y/N]: " CONT
    if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
        err "Aborted by user."
        exit 1
    fi
fi

# ---------- PHASE 2: DEPENDENCIES ----------
step "Phase 2: Install dependencies"

say "Updating apt index..."
apt-get update -y >/dev/null 2>&1

say "Installing auditd, rsyslog, curl, wget, acl, net-tools..."
apt-get install -y \
    auditd audispd-plugins rsyslog curl wget acl net-tools >/dev/null 2>&1
ok "Dependencies installed."

# Make sure auditd is running
systemctl enable auditd >/dev/null 2>&1 || true
systemctl start auditd >/dev/null 2>&1 || true
if systemctl is-active --quiet auditd; then
    ok "auditd is running."
else
    warn "auditd not running — will retry after install."
fi

# ---------- PHASE 3: INSTALL SPLUNK UF ----------
step "Phase 3: Install Splunk Universal Forwarder"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ -x "$UF_EXE" ]; then
    ok "Splunk UF already installed at $UF_HOME"
else
    say "Downloading Splunk Universal Forwarder .deb..."
    DEB_FILE="$WORK_DIR/splunkforwarder.deb"

    # Try multiple known-good URLs
    URLS=(
        "https://download.splunk.com/products/universalforwarder/releases/9.1.2/linux/splunkforwarder-9.1.2-b6b9c8185839-linux-2.6-amd64.deb"
        "https://download.splunk.com/products/universalforwarder/releases/9.0.4/linux/splunkforwarder-9.0.4-1d272c6a2e8b-linux-2.6-amd64.deb"
        "https://download.splunk.com/products/universalforwarder/releases/8.2.6/linux/splunkforwarder-8.2.6-a6fe1ee8894b-linux-2.6-amd64.deb"
    )

    DOWNLOADED=0
    for U in "${URLS[@]}"; do
        say "Trying: $U"
        if curl -fsSL --retry 2 --connect-timeout 10 -o "$DEB_FILE" "$U"; then
            if [ -s "$DEB_FILE" ]; then
                SIZE=$(du -h "$DEB_FILE" | cut -f1)
                ok "Downloaded $SIZE"
                DOWNLOADED=1
                break
            fi
        fi
    done

    if [ "$DOWNLOADED" -ne 1 ]; then
        err "All download URLs failed."
        echo ""
        echo "Manual fix:"
        echo "    1. Download the .deb from https://www.splunk.com/en_us/download/universal-forwarder.html"
        echo "       (Choose Linux, .deb for Ubuntu 64-bit)"
        echo "    2. Copy it to $DEB_FILE using scp from Win 11:"
        echo "         scp splunkforwarder-*.deb socadmin@192.168.10.130:/tmp/soc_uf/splunkforwarder.deb"
        echo "    3. Re-run: sudo bash $0"
        exit 1
    fi

    say "Installing .deb..."
    dpkg -i "$DEB_FILE" >/dev/null 2>&1
    APT_RC=$?
    if [ $APT_RC -ne 0 ]; then
        say "dpkg reported issues, running apt-get -f install..."
        apt-get install -f -y >/dev/null 2>&1 || true
    fi

    if [ -x "$UF_EXE" ]; then
        ok "Splunk UF installed successfully."
    else
        err "Splunk UF install failed. Check $DEB_FILE"
        exit 1
    fi
fi

# ---------- PHASE 4: CONFIGURE ----------
step "Phase 4: Write inputs.conf and outputs.conf"

LOCAL_DIR="$UF_HOME/etc/system/local"
mkdir -p "$LOCAL_DIR"

# Backup existing
TS=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/root/splunk_uf_backup_$TS"
mkdir -p "$BACKUP_DIR"
for f in inputs.conf outputs.conf; do
    if [ -f "$LOCAL_DIR/$f" ]; then
        cp "$LOCAL_DIR/$f" "$BACKUP_DIR/$f"
        say "Backed up $f -> $BACKUP_DIR/$f"
    fi
done

# --- outputs.conf ---
say "Writing outputs.conf -> ${SPLUNK_SERVER_IP}:${SPLUNK_PORT}"
cat > "$LOCAL_DIR/outputs.conf" <<EOF
[tcpout]
defaultGroup = primary_indexers

[tcpout:primary_indexers]
server = ${SPLUNK_SERVER_IP}:${SPLUNK_PORT}
useACK = false

[tcpout-server://${SPLUNK_SERVER_IP}:${SPLUNK_PORT}]
EOF
ok "outputs.conf written."

# --- inputs.conf ---
say "Writing inputs.conf"
cat > "$LOCAL_DIR/inputs.conf" <<EOF
[default]
host = ${SPLUNK_HOSTNAME}

# --- Authentication / SSH ---
[monitor://${LOG_AUTH}]
disabled = 0
sourcetype = linux_secure
index = linux_logs

# --- General system log ---
[monitor://${LOG_SYSLOG}]
disabled = 0
sourcetype = syslog
index = linux_logs

# --- Kernel log ---
[monitor://${LOG_KERN}]
disabled = 0
sourcetype = linux_kernel
index = linux_logs

# --- Audit daemon ---
[monitor://${LOG_AUDIT}]
disabled = 0
sourcetype = linux_audit
index = linux_logs

# --- Sample attack log ---
[monitor://${LOG_ATTACK}]
disabled = 0
sourcetype = linux_secure
index = linux_logs
EOF
ok "inputs.conf written."

# ---------- PHASE 5: PERMISSIONS ----------
step "Phase 5: Fix log file permissions"

# Make Splunk user exist (dpkg should have created it)
if ! id splunk >/dev/null 2>&1; then
    warn "Splunk user missing — creating"
    useradd -r -s /bin/false splunk 2>/dev/null || true
fi

for LOG in "$LOG_AUTH" "$LOG_SYSLOG" "$LOG_KERN"; do
    if [ -f "$LOG" ]; then
        chmod go+r "$LOG" 2>/dev/null && ok "Readable: $LOG"
    fi
done

if [ -f "$LOG_AUDIT" ]; then
    chmod 640 "$LOG_AUDIT" 2>/dev/null || true
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -m u:splunk:r "$LOG_AUDIT" 2>/dev/null && ok "ACL set on $LOG_AUDIT"
    fi
    # Also grant read on rotated logs
    setfacl -m u:splunk:r "$LOG_AUDIT".* 2>/dev/null || true
fi

if [ -f "$LOG_ATTACK" ]; then
    chmod 644 "$LOG_ATTACK" 2>/dev/null || true
    chown socadmin:socadmin "$LOG_ATTACK" 2>/dev/null || true
    ok "Attack log readable: $LOG_ATTACK"
else
    warn "Sample attack log not found at $LOG_ATTACK (optional)"
fi

# ---------- PHASE 6: START SERVICE ----------
step "Phase 6: Start SplunkForwarder"

say "First start (accepting license, seeding admin password)..."
"$UF_EXE" start --accept-license --answer-yes --no-prompt \
    --seed-passwd "$ADMIN_PASS" 2>&1 | grep -v "^$" | tail -n 8

say "Enabling boot-start..."
"$UF_EXE" enable boot-start -user splunk --accept-license --answer-yes --no-prompt 2>&1 | tail -n 3

say "Restarting to apply config..."
"$UF_EXE" restart 2>&1 | tail -n 5

say "Waiting 10 seconds..."
sleep 10

# ---------- PHASE 7: VERIFY ----------
step "Phase 7: Verification"

echo ""
say "Service status:"
"$UF_EXE" status 2>&1 | head -n 5

echo ""
say "Forward server:"
"$UF_EXE" list forward-server -auth "${ADMIN_USER}:${ADMIN_PASS}" 2>&1 | head -n 8

echo ""
say "Monitored files:"
"$UF_EXE" list monitor -auth "${ADMIN_USER}:${ADMIN_PASS}" 2>&1 | grep -E "^/" | head -n 10

echo ""
say "Recent connection log:"
tail -n 50 "$UF_HOME/var/log/splunk/splunkd.log" 2>/dev/null | \
    grep -iE "connect|idx|tcpout|error" | tail -n 5

echo ""
say "TCP to Splunk server:"
if nc -z -w 3 "${SPLUNK_SERVER_IP}" "${SPLUNK_PORT}" 2>/dev/null; then
    ok "TCP ${SPLUNK_SERVER_IP}:${SPLUNK_PORT} reachable."
else
    err "TCP ${SPLUNK_SERVER_IP}:${SPLUNK_PORT} NOT reachable."
    warn "Check Win 11 firewall and Splunk receiver:"
    warn "  netstat -ano | findstr :9997"
    warn "  New-NetFirewallRule -DisplayName 'Splunk 9997' -Direction Inbound -Protocol TCP -LocalPort 9997 -Action Allow"
fi

# Force a fresh read
say "Appending a test line to trigger fresh read..."
logger "SOC-LAB-UBUNTU-TEST from $(hostname) at $(date)" 2>/dev/null || true
if [ -f "$LOG_ATTACK" ]; then
    echo "FORCE-READ $(date)" >> "$LOG_ATTACK" 2>/dev/null || true
fi

# ---------- SUMMARY ----------
step "Done"

echo ""
ok "Ubuntu Splunk Forwarder setup complete."
echo ""
echo "============================================================="
echo " Next: Open Splunk Web on Win 11"
echo "============================================================="
echo ""
echo "  Browser : http://localhost:8000"
echo "  Login   : socadmin / P@ssw0rd2026!"
echo ""
echo " SPL queries to verify:"
echo ""
echo "  # Is Ubuntu alive?"
echo "  index=linux_logs host=srv-linux-01 earliest=-5m"
echo "  | stats count as events"
echo "  | eval status=if(events>0,\"UP\",\"DOWN\")"
echo "  | table status, events"
echo ""
echo "  # What sourcetypes are arriving?"
echo "  index=linux_logs host=srv-linux-01 earliest=-15m"
echo "  | stats count by sourcetype"
echo ""
echo "  # See raw events"
echo "  index=linux_logs host=srv-linux-01 earliest=-15m | head 20"
echo ""
echo " Local check commands:"
echo "  sudo /opt/splunkforwarder/bin/splunk status"
echo "  sudo /opt/splunkforwarder/bin/splunk list forward-server -auth admin:P@ssw0rd2026!"
echo "  sudo /opt/splunkforwarder/bin/splunk list monitor -auth admin:P@ssw0rd2026!"
echo "  sudo tail -f /opt/splunkforwarder/var/log/splunk/splunkd.log"
echo ""
echo " Backups: $BACKUP_DIR"
echo ""
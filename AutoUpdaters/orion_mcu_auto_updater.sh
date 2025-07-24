#!/usr/bin/env bash
set -euo pipefail

# MCU Auto-Updater for CM5 (runs hourly via cron)
# Uses GPIO18=SWDIO, GPIO15=SWCLK, GPIO20=RESET; UART RX=GPIO5, TX=GPIO4

WORKDIR="$HOME/Documents"
ORION_REPO="$WORKDIR/Orion-Software-Pack"
STACK_ARCHIVE="$ORION_REPO/OrionStack.tar.gz.enc"
KEYFILE="$WORKDIR/key_hsio.bin"
LOCAL_VER_FILE="$WORKDIR/mcu_firmware_version_code.txt"
SERIAL_PORT="/dev/serial0"   # adjust if needed for UART4 on GPIO4/5
BAUDRATE=115200

log() { echo "[$(date '+%F %T')] $*"; }

log "Starting MCU auto-update check..."

# 1) Update the Orion repo
cd "$ORION_REPO"
if git rev-parse --is-inside-work-tree &>/dev/null; then
  git pull --ff-only origin main
else
  log "✗ Orion repo not found, aborting"
  exit 1
fi

# 2) Decrypt and read remote version
if [[ ! -f "mcu_vs.txt" ]]; then
  log "✗ mcu_vs.txt missing in repo, aborting"
  exit 1
fi
REMOTE_VER=$(openssl enc -d -aes-256-cbc -salt \
  -in mcu_vs.txt -pass file:"$KEYFILE" 2>/dev/null \
  | grep -Eo '[0-9]+' || echo "0")
log "Remote firmware version: $REMOTE_VER"

# 3) Read local version
if [[ -f "$LOCAL_VER_FILE" ]]; then
  LOCAL_VER=$(<"$LOCAL_VER_FILE")
else
  LOCAL_VER=0
fi
log "Local firmware version:  $LOCAL_VER"

# 4) Compare versions
if (( REMOTE_VER <= LOCAL_VER )); then
  log "No update needed. Exiting."
  exit 0
fi
log "New version available: $REMOTE_VER > $LOCAL_VER"

# 5) Decrypt & extract the updated OrionStack archive
mkdir -p "$WORKDIR/OrionStack"
openssl enc -d -aes-256-cbc -salt \
  -in "$STACK_ARCHIVE" -pass file:"$KEYFILE" \
| tar xz -C "$WORKDIR"

# 6) Locate the new UF2
NEW_UF2=$(find "$WORKDIR/OrionStack" -maxdepth 1 -type f -name '*.uf2' | head -n1)
if [[ -z "$NEW_UF2" ]]; then
  log "✗ No UF2 found in OrionStack, aborting"
  exit 1
fi
log "Found new UF2: $NEW_UF2"

# 7) Configure UART
stty -F "$SERIAL_PORT" "$BAUDRATE" raw -echo

# 8) Warn MCU and await ack
WARN_MSG="UPDATE_AVAILABLE:$REMOTE_VER"
END=$((SECONDS + 300))
WAIT_SEC=0
while true; do
  echo -n "$WARN_MSG" > "$SERIAL_PORT"
  if read -r -t 2 REPLY < "$SERIAL_PORT"; then
    if [[ $REPLY =~ ACK:([0-9]+) ]]; then
      WAIT_SEC=${BASH_REMATCH[1]}
      log "MCU ack received, waiting $WAIT_SEC seconds before flash"
      break
    fi
  fi
  if (( SECONDS >= END )); then
    WAIT_SEC=300
    log "No MCU ack after 300s, defaulting wait $WAIT_SEC seconds"
    break
  fi
  sleep 2
done

# 9) Delay before flashing
log "Sleeping $WAIT_SEC seconds..."
sleep "$WAIT_SEC"

# 10) Prepare SWD config
cat > /tmp/rp2350_swd.cfg <<EOF
interface bcm2835gpio
bcm2835gpio_swd_nums 18 15
bcm2835gpio_trst_num 20
transport select swd
reset_config srst_only srst_nogate
source [find target/rp2040.cfg]
EOF

# 11) Convert UF2 → BIN
BIN="/tmp/mcu_update.bin"
uf2conv "$NEW_UF2" -o "$BIN"

# 12) Flash via OpenOCD
log "Flashing MCU..."
sudo openocd -f /tmp/rp2350_swd.cfg \
  -c "init; reset halt; program $BIN verify reset; exit"

# 13) Update local version file
echo "$REMOTE_VER" > "$LOCAL_VER_FILE"
log "Update complete: now at version $REMOTE_VER"

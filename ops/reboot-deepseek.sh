#!/usr/bin/env bash
# Full power-cycle recovery for the 2-node DeepSeek-V4 cluster (head + worker),
# pinned to DeepSeek-V4-Flash-0731.
#
#   [1/4] cleanly stop both container ranks (docker down)
#   [2/4] reboot the WORKER, wait until it is fully back
#   [3/4] confirm the persistent boot unit is enabled on the HEAD
#   [4/4] reboot the HEAD  (ends this script; the boot unit finishes the job)
#
# Why the ceremony: a single-node reboot leaves the surviving rank hung at NCCL
# rendezvous, so BOTH nodes must come back fresh. Stopping first prevents any
# auto-restarting container from coming up into a broken rendezvous.
#
# Step [3/4] used to WRITE and enable a one-shot unit here. It no longer does:
# deepseek-v4-flash.service is permanently enabled, so the cluster also returns
# from power events nobody got to arm — an unplanned outage being precisely the
# case where a pre-armed one-shot is not available. All this step does now is
# refuse to reboot the head if that unit is missing or disabled, which would
# otherwise leave the cluster down until someone noticed.
#
# Run from the HEAD (the head node). Pass --yes / -y to skip the confirmation.
set -euo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/deepseek-lib.sh"
[ -r "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
# shellcheck source=/dev/null
source "$LIB"

STOP_ADAPTER_PROFILE="$DS_PROFILE"
UNIT_NAME="deepseek-v4-flash.service"
WORKER_HOST="$DS_WORKER_HOST"

ssh_worker() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$WORKER_HOST" "$@"; }

confirm() {
  case "${1:-}" in
    -y|--yes) return 0 ;;
  esac
  echo "This will REBOOT BOTH nodes:"
  echo "  worker: $WORKER_HOST"
  echo "  head:   $(hostname)  (this machine — your session WILL drop)"
  echo
  read -r -p "Type 'reboot' to proceed: " ans
  [ "$ans" = "reboot" ] || { echo "Aborted."; exit 1; }
}

wait_worker_down() {
  echo "Waiting for worker to go offline..."
  for _ in $(seq 1 60); do
    ssh_worker true >/dev/null 2>&1 || { echo "  worker is offline"; return 0; }
    sleep 3
  done
  echo "  worker still reachable after timeout; continuing." >&2
}

wait_worker_up() {
  echo "Waiting for worker to come back (sshd + docker + persistenced socket)..."
  for _ in $(seq 1 120); do
    if ssh_worker 'docker info >/dev/null 2>&1 && test -S /run/nvidia-persistenced/socket'; then
      echo "  worker is back up"; return 0
    fi
    sleep 5
  done
  echo "Worker did not return within timeout — aborting BEFORE head reboot so you" >&2
  echo "are not left with a half-cycled cluster. Investigate the worker, then retry." >&2
  exit 1
}

check_boot_unit() {
  echo "Checking persistent boot unit ($UNIT_NAME)..."
  if ! systemctl cat "$UNIT_NAME" >/dev/null 2>&1; then
    echo "  ERROR: $UNIT_NAME is not installed — the head would come back with no" >&2
    echo "  cluster. Install it before rebooting." >&2
    exit 1
  fi
  if ! systemctl is-enabled --quiet "$UNIT_NAME"; then
    echo "  $UNIT_NAME is installed but disabled; enabling it now."
    sudo -n systemctl enable "$UNIT_NAME"
  fi
  echo "  $UNIT_NAME enabled — cluster will self-start after boot"
}

main() {
  confirm "${1:-}"

  echo "== [1/4] Stopping cluster cleanly (profile=$STOP_ADAPTER_PROFILE) =="
  ds_clear_ranks

  echo "== [2/4] Rebooting worker $WORKER_HOST =="
  ssh_worker 'sudo -n systemctl --no-block reboot' || true
  wait_worker_down
  wait_worker_up

  echo "== [3/4] Verifying boot-start is armed on head =="
  check_boot_unit

  echo "== [4/4] Rebooting head now — cluster auto-starts after boot =="
  echo "After it returns, watch:  journalctl -u $UNIT_NAME -f"
  echo "Boot-start log:           $SCRIPT_DIR/logs/boot-deepseek-*.log"
  sync
  sleep 3
  sudo -n systemctl --no-block reboot
}

main "$@"

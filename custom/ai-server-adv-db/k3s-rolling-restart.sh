#!/usr/bin/env bash

set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o StrictHostKeyChecking=accept-new
)

DRY_RUN=false
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-240}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-5}"
POST_READY_PAUSE_SECONDS="${POST_READY_PAUSE_SECONDS:-20}"
LOG_ROOT="${LOG_ROOT:-$(pwd)/custom/ai-server-adv-db/k3s-rolling-restart-logs}"
TIMESTAMP="$(date +%F-%H%M%S)"
LOG_DIR="$LOG_ROOT/$TIMESTAMP"
NODES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --wait-timeout)
      WAIT_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --check-interval)
      CHECK_INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --post-ready-pause)
      POST_READY_PAUSE_SECONDS="$2"
      shift 2
      ;;
    --log-root)
      LOG_ROOT="$2"
      LOG_DIR="$LOG_ROOT/$TIMESTAMP"
      shift 2
      ;;
    --)
      shift
      NODES=("$@")
      break
      ;;
    adtiger-*)
      NODES+=("$1")
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [ "${#NODES[@]}" -eq 0 ]; then
  NODES=(adtiger-eq adtiger-eq-2 adtiger-eq-3)
fi

mkdir -p "$LOG_DIR"

log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*"
}

ssh_root() {
  local node="$1"
  shift
  ssh "${SSH_OPTS[@]}" "root@$node" "$@"
}

node_name_for_kubectl() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

capture_status() {
  local node="$1"
  local log_file="$LOG_DIR/$node-status.txt"

  ssh_root "$node" '
set -euo pipefail
echo "=== $(hostname) $(date -Is) ==="
systemctl is-active k3s || true
systemctl status k3s --no-pager -l || true
/usr/local/bin/k3s kubectl get --raw=/readyz?verbose || true
' > "$log_file" 2>&1 || true
}

restart_node() {
  local node="$1"

  if [ "$DRY_RUN" = true ]; then
    log INFO "dry-run: would restart k3s on $node"
    return 0
  fi

  log INFO "restarting k3s on $node"
  ssh_root "$node" 'systemctl restart k3s'
}

wait_for_node() {
  local node="$1"
  local kube_node
  local deadline

  kube_node="$(node_name_for_kubectl "$node")"
  deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ssh_root "$node" "set -euo pipefail; \
      systemctl is-active --quiet k3s && \
      /usr/local/bin/k3s kubectl get --raw=/readyz?verbose >/dev/null && \
      [ \"\$(/usr/local/bin/k3s kubectl get node '$kube_node' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]" \
      >/dev/null 2>&1; then
      log INFO "$node is healthy again"
      return 0
    fi

    sleep "$CHECK_INTERVAL_SECONDS"
  done

  log ERROR "$node did not become healthy within ${WAIT_TIMEOUT_SECONDS}s"
  capture_status "$node"
  return 1
}

main() {
  local node

  log INFO "rolling restart order: ${NODES[*]}"
  log INFO "logs: $LOG_DIR"

  for node in "${NODES[@]}"; do
    restart_node "$node"

    if [ "$DRY_RUN" = true ]; then
      continue
    fi

    if ! wait_for_node "$node"; then
      log ERROR "stopping rollout after failure on $node"
      exit 1
    fi

    sleep "$POST_READY_PAUSE_SECONDS"
  done

  log INFO "rolling restart completed"
}

main
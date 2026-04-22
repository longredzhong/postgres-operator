#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(pwd)/custom/ai-server-adv-db/k3s-5am-debug}"
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o StrictHostKeyChecking=accept-new
)
if [ "$#" -gt 0 ]; then
  NODES=("$@")
else
  NODES=(adtiger-eq adtiger-eq-2 adtiger-eq-3)
fi
TIMESTAMP="$(date +%F-%H%M%S)"

mkdir -p "$ROOT_DIR/$TIMESTAMP"

run_remote() {
  local node="$1"
  local out_dir="$ROOT_DIR/$TIMESTAMP/$node"
  mkdir -p "$out_dir"

  echo "==> collecting from $node"

  ssh "${SSH_OPTS[@]}" "root@$node" '
set -euo pipefail

OUT_BASE="/tmp/k3s-5am-debug"
TS="$(date +%F-%H%M%S)"
SINCE_TS="$(date +%F) 04:50:00"
OUT_DIR="$OUT_BASE/$TS"
mkdir -p "$OUT_DIR"

date -Is > "$OUT_DIR/start-time.txt"
hostname > "$OUT_DIR/hostname.txt"
id -un > "$OUT_DIR/user.txt"

systemctl is-active k3s > "$OUT_DIR/k3s-active.txt" 2>&1 || true
systemctl status k3s --no-pager -l > "$OUT_DIR/k3s-status.txt" 2>&1 || true
journalctl -u k3s --since "$SINCE_TS" --no-pager > "$OUT_DIR/k3s-journal-since-0450.txt" 2>&1 || true

/usr/local/bin/k3s kubectl get --raw=/livez?verbose > "$OUT_DIR/apiserver-livez.txt" 2>&1 || true
/usr/local/bin/k3s kubectl get --raw=/readyz?verbose > "$OUT_DIR/apiserver-readyz.txt" 2>&1 || true
/usr/local/bin/k3s kubectl get nodes -o wide > "$OUT_DIR/kubectl-nodes.txt" 2>&1 || true
/usr/local/bin/k3s kubectl get pods -A -o wide > "$OUT_DIR/kubectl-pods-all.txt" 2>&1 || true
/usr/local/bin/k3s kubectl get events -n kube-system --sort-by=.lastTimestamp > "$OUT_DIR/kube-system-events.txt" 2>&1 || true
/usr/local/bin/k3s kubectl get lease -A > "$OUT_DIR/leases-all.txt" 2>&1 || true
/usr/local/bin/k3s kubectl -n kube-system get pods -o wide > "$OUT_DIR/kube-system-pods.txt" 2>&1 || true
/usr/local/bin/k3s kubectl -n kube-system logs -l name=kube-vip-ds --since=30m --all-containers=true > "$OUT_DIR/kube-vip-logs.txt" 2>&1 || true
/usr/local/bin/k3s kubectl -n kube-system logs deploy/kube-vip-cloud-provider --since=30m --all-containers=true > "$OUT_DIR/kube-vip-cloud-provider.txt" 2>&1 || true
/usr/local/bin/k3s kubectl -n kube-system logs deploy/coredns --since=30m --all-containers=true > "$OUT_DIR/coredns.txt" 2>&1 || true

ss -lntp > "$OUT_DIR/ss-lntp.txt" 2>&1 || true
ip -br a > "$OUT_DIR/ip-brief.txt" 2>&1 || true
ip route > "$OUT_DIR/ip-route.txt" 2>&1 || true

if command -v tailscale >/dev/null 2>&1; then
  tailscale status > "$OUT_DIR/tailscale-status.txt" 2>&1 || true
  journalctl -u tailscaled --since "$SINCE_TS" --no-pager > "$OUT_DIR/tailscaled-journal-since-0450.txt" 2>&1 || true
fi

ETCDCTL_PATH="$(command -v etcdctl || true)"
if [ -z "$ETCDCTL_PATH" ]; then
  ETCDCTL_PATH="$(find /var/lib/rancher/k3s -type f -name etcdctl -print -quit 2>/dev/null || true)"
fi

if [ -f /var/lib/rancher/k3s/server/tls/etcd/server-ca.crt ] && [ -f /var/lib/rancher/k3s/server/tls/etcd/client.crt ] && [ -f /var/lib/rancher/k3s/server/tls/etcd/client.key ] && [ -n "$ETCDCTL_PATH" ]; then
  ETCDCTL_API=3 "$ETCDCTL_PATH" \
    --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
    --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
    --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
    --endpoints=https://127.0.0.1:2379 endpoint health > "$OUT_DIR/etcd-endpoint-health.txt" 2>&1 || true

  ETCDCTL_API=3 "$ETCDCTL_PATH" \
    --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
    --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
    --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
    --endpoints=https://127.0.0.1:2379 endpoint status -w table > "$OUT_DIR/etcd-endpoint-status.txt" 2>&1 || true

  ETCDCTL_API=3 "$ETCDCTL_PATH" \
    --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
    --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
    --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
    --endpoints=https://127.0.0.1:2379 member list -w table > "$OUT_DIR/etcd-member-list.txt" 2>&1 || true
elif [ -f /var/lib/rancher/k3s/server/tls/etcd/server-ca.crt ]; then
  echo "etcdctl not found on node" > "$OUT_DIR/etcd-endpoint-health.txt"
  echo "etcdctl not found on node" > "$OUT_DIR/etcd-endpoint-status.txt"
  echo "etcdctl not found on node" > "$OUT_DIR/etcd-member-list.txt"
fi

echo "$OUT_DIR"
  ' > "$out_dir/remote-path.txt"

  remote_path="$(tail -n 1 "$out_dir/remote-path.txt")"
  scp "${SSH_OPTS[@]}" -r "root@$node:$remote_path/." "$out_dir/" >/dev/null
  echo "$remote_path" > "$out_dir/remote-archive-path.txt"
}

for node in "${NODES[@]}"; do
  run_remote "$node"
done

echo "local artifacts: $ROOT_DIR/$TIMESTAMP"
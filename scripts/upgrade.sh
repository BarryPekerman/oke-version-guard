#!/usr/bin/env bash
# ============================================================================
# upgrade.sh — upgrade an OKE Basic cluster by ONE minor version, safely, on
# the Always-Free tier (no surge, one node at a time, DB volumes preserved).
#
# Env:
#   OCI_CLUSTER_ID   (required)  OCID of the OKE cluster
#   OCI_REGION       (required)  e.g. il-jerusalem-1
#   TARGET_VERSION   (required)  e.g. v1.35.0  (must be exactly one minor above current)
#   KUBECONFIG       (required)  kubeconfig for draining nodes
#   SNAPSHOT         (optional)  "true" to back up attached block volumes first
# Requires: oci CLI (authenticated), kubectl, jq
#
# Order: preflight -> (snapshot) -> control plane -> node pool template ->
#        cycle nodes one-at-a-time (delete-node, no size decrement) -> verify.
# ============================================================================
set -euo pipefail

: "${OCI_CLUSTER_ID:?}" ; : "${OCI_REGION:?}" ; : "${TARGET_VERSION:?}" ; : "${KUBECONFIG:?}"
R=(--region "$OCI_REGION")
log() { echo "==> $*"; }

# --- Preflight: refuse to touch a cluster that isn't already healthy ---
log "Preflight health check"
state=$(oci ce cluster get --cluster-id "$OCI_CLUSTER_ID" "${R[@]}" --query 'data."lifecycle-state"' --raw-output)
[ "$state" = "ACTIVE" ] || { echo "Cluster not ACTIVE (is $state); aborting." >&2; exit 1; }
kubectl get --raw='/readyz' >/dev/null || { echo "apiserver /readyz failed; aborting." >&2; exit 1; }
if kubectl get nodes --no-headers | grep -qv ' Ready '; then echo "A node is not Ready; aborting." >&2; exit 1; fi
if kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"{print; f=1} END{exit f?1:0}'; then :; else
  echo "Unhealthy pods present; aborting." >&2; exit 1; fi

# --- Discover the (single) node pool ---
NODE_POOL_ID=$(oci ce node-pool list --cluster-id "$OCI_CLUSTER_ID" \
  --compartment-id "$(oci ce cluster get --cluster-id "$OCI_CLUSTER_ID" "${R[@]}" --query 'data."compartment-id"' --raw-output)" \
  "${R[@]}" --query 'data[0].id' --raw-output)
[ -n "$NODE_POOL_ID" ] && [ "$NODE_POOL_ID" != "null" ] || { echo "No node pool found; aborting." >&2; exit 1; }
log "Node pool: $NODE_POOL_ID"

# --- Optional: snapshot attached block volumes as a safety net ---
if [ "${SNAPSHOT:-false}" = "true" ]; then
  log "Backing up attached block volumes (best effort)"
  COMPART=$(oci ce cluster get --cluster-id "$OCI_CLUSTER_ID" "${R[@]}" --query 'data."compartment-id"' --raw-output)
  for vol in $(oci bv volume list --compartment-id "$COMPART" "${R[@]}" \
      --query 'data[?"lifecycle-state"==`AVAILABLE`].id' --raw-output | tr -d '[],"'); do
    oci bv backup create --volume-id "$vol" "${R[@]}" --type INCREMENTAL \
      --display-name "pre-upgrade-$(echo "$vol" | tail -c 8)" >/dev/null 2>&1 || true
  done
fi

wait_active() {
  for _ in $(seq 1 60); do
    [ "$(oci ce cluster get --cluster-id "$OCI_CLUSTER_ID" "${R[@]}" --query 'data."lifecycle-state"' --raw-output)" = "ACTIVE" ] && return 0
    sleep 20
  done; return 1
}

# --- 1) Control plane (non-disruptive) ---
log "Upgrading control plane -> $TARGET_VERSION"
oci ce cluster update --cluster-id "$OCI_CLUSTER_ID" "${R[@]}" \
  --kubernetes-version "$TARGET_VERSION" --wait-for-state SUCCEEDED >/dev/null
wait_active || { echo "Control plane did not return ACTIVE; aborting." >&2; exit 1; }

# --- 2) Node pool template (new nodes will boot at TARGET) ---
log "Updating node pool template -> $TARGET_VERSION"
oci ce node-pool update --node-pool-id "$NODE_POOL_ID" "${R[@]}" \
  --kubernetes-version "$TARGET_VERSION" --wait-for-state SUCCEEDED >/dev/null

# --- 3) Cycle nodes one at a time, NO surge (stay within 4-OCPU free cap) ---
# Map OKE node OCIDs -> private IPs (kubectl node name == private IP on OKE).
mapfile -t NODE_LINES < <(oci ce node-pool get --node-pool-id "$NODE_POOL_ID" "${R[@]}" \
  --query 'data.nodes[].{id:id,ip:"private-ip",ver:"kubernetes-version"}' --output json \
  | jq -r '.[] | "\(.id) \(.ip) \(.ver)"')

for line in "${NODE_LINES[@]}"; do
  NODE_ID=$(echo "$line" | awk '{print $1}')
  NODE_IP=$(echo "$line" | awk '{print $2}')
  NODE_VER=$(echo "$line" | awk '{print $3}')
  if [ "$NODE_VER" = "$TARGET_VERSION" ]; then log "Node $NODE_IP already at $TARGET_VERSION, skipping"; continue; fi

  log "Draining $NODE_IP"
  kubectl cordon "$NODE_IP" || true
  kubectl drain "$NODE_IP" --ignore-daemonsets --delete-emptydir-data --timeout=300s || true

  log "Deleting node $NODE_IP (pool recreates a replacement at $TARGET_VERSION, no size decrement)"
  oci ce node-pool delete-node --node-pool-id "$NODE_POOL_ID" --node-id "$NODE_ID" \
    --is-decrement-size false "${R[@]}" --force >/dev/null

  # Wait for the pool to be back to desired size with all nodes Ready at TARGET.
  log "Waiting for replacement node to join and become Ready"
  ok=false
  for _ in $(seq 1 45); do
    ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
    want=$(oci ce node-pool get --node-pool-id "$NODE_POOL_ID" "${R[@]}" --query 'data."node-config-details".size' --raw-output)
    if [ "$ready" = "$want" ] && ! kubectl get nodes --no-headers | grep -qv ' Ready '; then ok=true; break; fi
    sleep 20
  done
  $ok || { echo "Replacement node did not become Ready in time; aborting before next node." >&2; exit 1; }
done

# --- 4) Final verification ---
log "Verifying cluster health post-upgrade"
kubectl get --raw='/readyz' >/dev/null || { echo "post-upgrade /readyz failed" >&2; exit 1; }
kubectl get nodes -o wide
echo "Upgrade to $TARGET_VERSION complete."

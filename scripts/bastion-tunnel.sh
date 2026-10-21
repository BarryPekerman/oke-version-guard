#!/usr/bin/env bash
# ============================================================================
# bastion-tunnel.sh — reach a private OKE API endpoint through the OCI Bastion.
#
# Opens a bastion port-forward session (throwaway SSH key), forwards
# 127.0.0.1:6443 to the API's private endpoint in the background, and writes a
# kubeconfig pointing at the tunnel (TLS name kept as the API's private IP,
# which the certificate is issued for).
#
# Env:
#   OCI_CLUSTER_ID   (required)  OCID of the OKE cluster
#   OCI_REGION       (required)  e.g. il-jerusalem-1
#   OCI_BASTION_ID   (required)  OCID of a bastion whose target subnet can reach the API
#   KUBECONFIG       (required)  where to write the kubeconfig
# On GitHub Actions, exports BASTION_SESSION_ID so a final step can delete the session:
#   oci bastion session delete --session-id "$BASTION_SESSION_ID" --force
# Requires: oci CLI (authenticated), ssh, kubectl
# ============================================================================
set -euo pipefail

: "${OCI_CLUSTER_ID:?}" ; : "${OCI_REGION:?}" ; : "${OCI_BASTION_ID:?}" ; : "${KUBECONFIG:?}"
R=(--region "$OCI_REGION")
log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

ENDPOINT=$(oci ce cluster get --cluster-id "$OCI_CLUSTER_ID" "${R[@]}" \
  --query 'data.endpoints."private-endpoint"' --raw-output)
API_IP="${ENDPOINT%:*}"
API_PORT="${ENDPOINT##*:}"

KEY_DIR="${RUNNER_TEMP:-$(mktemp -d)}/bastion"
mkdir -p "$KEY_DIR"
ssh-keygen -q -t ed25519 -N '' -C oke-version-guard -f "$KEY_DIR/key"

# 3 hours (the service maximum); a whole upgrade has taken ~10 minutes.
log "Creating bastion session"
SESSION_ID=$(oci bastion session create-port-forwarding "${R[@]}" \
  --bastion-id "$OCI_BASTION_ID" --display-name "oke-version-guard-${GITHUB_RUN_ID:-local}" \
  --target-private-ip "$API_IP" --target-port "$API_PORT" \
  --ssh-public-key-file "$KEY_DIR/key.pub" --session-ttl 10800 \
  --query 'data.id' --raw-output)
[ -n "${GITHUB_ENV:-}" ] && echo "BASTION_SESSION_ID=$SESSION_ID" >> "$GITHUB_ENV"

state=""
for _ in $(seq 1 60); do
  state=$(oci bastion session get --session-id "$SESSION_ID" "${R[@]}" \
    --query 'data."lifecycle-state"' --raw-output)
  [ "$state" = "ACTIVE" ] && break
  [ "$state" = "FAILED" ] && die "bastion session FAILED"
  sleep 3
done
[ "$state" = "ACTIVE" ] || die "bastion session not ACTIVE after 3 minutes"

# A freshly ACTIVE session can refuse SSH for a few seconds; retry briefly.
log "Opening tunnel 127.0.0.1:6443 -> private API endpoint"
ok=""
for attempt in 1 2 3 4 5 6; do
  if ssh -f -N -i "$KEY_DIR/key" -p 22 \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KEY_DIR/known_hosts" \
      -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
      -L "127.0.0.1:6443:${API_IP}:${API_PORT}" \
      "${SESSION_ID}@host.bastion.${OCI_REGION}.oci.oraclecloud.com"; then
    ok=1; break
  fi
  echo "  SSH not accepted yet (attempt $attempt), retrying"
  sleep 10
done
[ -n "$ok" ] || die "could not open the SSH tunnel"

mkdir -p "$(dirname "$KUBECONFIG")"
oci ce cluster create-kubeconfig --cluster-id "$OCI_CLUSTER_ID" "${R[@]}" \
  --file "$KUBECONFIG" --token-version 2.0.0 --kube-endpoint PRIVATE_ENDPOINT >/dev/null
cluster=$(kubectl config view -o jsonpath='{.clusters[0].name}')
kubectl config set-cluster "$cluster" --server="https://127.0.0.1:6443" --tls-server-name="$API_IP" >/dev/null
log "Tunnel up; kubeconfig at $KUBECONFIG"

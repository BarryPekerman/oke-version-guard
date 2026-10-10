#!/usr/bin/env bash
# ============================================================================
# upgrade.sh — upgrade an OKE Basic cluster by ONE minor version (or to a newer
# patch of the current minor), safely, on the Always-Free tier (no surge, one
# node at a time, DB volumes preserved).
#
# Env:
#   OCI_CLUSTER_ID   (required)  OCID of the OKE cluster
#   OCI_REGION       (required)  e.g. il-jerusalem-1
#   TARGET_VERSION   (required)  e.g. v1.35.2 — a supported version that is either
#                                a newer patch of the current minor or exactly one minor up.
#                                Equal to the control plane's version = resume a partial
#                                upgrade (finish node pools / nodes still on the old version).
#   KUBECONFIG       (required)  kubeconfig for draining nodes
#   SNAPSHOT         (optional)  "true" to back up volumes attached to cluster nodes first
#                                (keeps only the newest pre-upgrade backup per volume)
# Requires: oci CLI (authenticated), kubectl, jq
#
# Order: preflight -> (snapshot) -> control plane -> node pool templates ->
#        cycle nodes one-at-a-time (delete-node, no size decrement) -> verify.
# ============================================================================
set -euo pipefail

: "${OCI_CLUSTER_ID:?}" ; : "${OCI_REGION:?}" ; : "${TARGET_VERSION:?}" ; : "${KUBECONFIG:?}"
R=(--region "$OCI_REGION")
WAIT=(--max-wait-seconds 3600)   # CLI default (1200s) is shorter than a control-plane upgrade can take
log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# `oci ... --raw-output`, minus the quotes/whitespace some CLI builds leave on it.
ociv() { local s; s=$(oci "$@" --raw-output); s="${s//\"/}"; printf '%s' "${s//[[:space:]]/}"; }
minor_key() { local v="${1//[^0-9.]/}"; local maj="${v%%.*}"; local rest="${v#*.}"; local min="${rest%%.*}"; echo $(( ${maj:-0} * 1000 + ${min:-0} )); }
cluster_get() { ociv ce cluster get --cluster-id "$OCI_CLUSTER_ID" "${R[@]}" --query "data.\"$1\""; }

# Nodes that are not Ready (cordoned-but-Ready nodes are fine).
not_ready_nodes() {
  kubectl get nodes -o json | jq -r '.items[]
    | select([.status.conditions[] | select(.type=="Ready") | .status] != ["True"]) | .metadata.name'
}
ready_node_count() {
  kubectl get nodes -o json | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready") | .status=="True")] | length'
}

# --- Validate target: supported, and a newer patch or exactly one minor up ---
CURRENT=$(cluster_get kubernetes-version)
oci ce cluster-options get --cluster-option-id all "${R[@]}" \
  --query 'data."kubernetes-versions"' --output json | jq -e --arg t "$TARGET_VERSION" 'index($t) != null' >/dev/null \
  || die "$TARGET_VERSION is not in OKE's supported version list"
delta=$(( $(minor_key "$TARGET_VERSION") - $(minor_key "$CURRENT") ))
if [ "$CURRENT" = "$TARGET_VERSION" ]; then
  log "Control plane already at $TARGET_VERSION — resuming node pool / node upgrade"
elif [ "$delta" -eq 0 ]; then
  [ "$CURRENT" != "$TARGET_VERSION" ] && [ "$(printf '%s\n%s\n' "$CURRENT" "$TARGET_VERSION" | sort -V | tail -1)" = "$TARGET_VERSION" ] \
    || die "$TARGET_VERSION is older than current $CURRENT"
elif [ "$delta" -ne 1 ]; then
  die "$CURRENT -> $TARGET_VERSION is not a patch or single-minor step (OKE never skips minors)"
fi
[ "$CURRENT" = "$TARGET_VERSION" ] || log "Upgrading $CURRENT -> $TARGET_VERSION"

# --- Preflight: refuse to touch a cluster that isn't already healthy ---
log "Preflight health check"
state=$(cluster_get lifecycle-state)
[ "$state" = "ACTIVE" ] || die "Cluster not ACTIVE (is $state); aborting."
kubectl get --raw='/readyz' >/dev/null || die "apiserver /readyz failed; aborting."
bad=$(not_ready_nodes); [ -z "$bad" ] || die "Node(s) not Ready: $bad; aborting."
# Pending/Unknown pods or crash/pull loops abort; finished pods (Completed/Error/Evicted) don't.
bad=$(kubectl get pods -A -o json | jq -r '.items[]
  | select(.status.phase=="Pending" or .status.phase=="Unknown"
      or ([.status.containerStatuses[]?.state.waiting.reason]
          | any(. == "CrashLoopBackOff" or . == "ImagePullBackOff" or . == "ErrImagePull")))
  | "\(.metadata.namespace)/\(.metadata.name)"')
[ -z "$bad" ] || die "Unhealthy pods present; aborting:"$'\n'"$bad"

# --- Discover node pools ---
COMPART=$(cluster_get compartment-id)
mapfile -t NODE_POOLS < <(oci ce node-pool list --cluster-id "$OCI_CLUSTER_ID" --compartment-id "$COMPART" \
  "${R[@]}" --output json | jq -r '.data[].id')
[ "${#NODE_POOLS[@]}" -gt 0 ] || die "No node pool found; aborting."
log "Node pools: ${NODE_POOLS[*]}"

pool_nodes() { # "<node-ocid> <private-ip> <k8s-version>" per live node
  # OKE keeps DELETED nodes in the pool's node list for a while after cycling.
  oci ce node-pool get --node-pool-id "$1" "${R[@]}" --output json \
    | jq -r '.data.nodes[] | select(."lifecycle-state" != "DELETED" and ."lifecycle-state" != "DELETING")
        | "\(.id) \(."private-ip") \(."kubernetes-version")"'
}
desired_nodes() { local p n=0; for p in "${NODE_POOLS[@]}"; do
  n=$(( n + $(ociv ce node-pool get --node-pool-id "$p" "${R[@]}" --query 'data."node-config-details".size') )); done; echo "$n"; }

# --- Optional: back up volumes attached to cluster nodes (i.e. PVCs) ---
if [ "${SNAPSHOT:-false}" = "true" ]; then
  log "Backing up volumes attached to cluster nodes"
  # Plain loops (no process substitution) so a failed OCI call aborts instead of yielding "no volumes".
  VOLS=()
  for p in "${NODE_POOLS[@]}"; do
    nodes=$(pool_nodes "$p")
    while read -r id _ _; do
      [ -n "$id" ] || continue
      atts=$(oci compute volume-attachment list --compartment-id "$COMPART" --instance-id "$id" "${R[@]}" --all --output json)
      mapfile -t -O "${#VOLS[@]}" VOLS < <(jq -r '.data[]? | select(."lifecycle-state"=="ATTACHED") | ."volume-id"' <<<"$atts")
    done <<<"$nodes"
  done
  mapfile -t VOLS < <(printf '%s\n' "${VOLS[@]}" | sed '/^$/d' | sort -u)
  [ "${#VOLS[@]}" -gt 0 ] || log "No attached volumes; nothing to back up"
  for vol in "${VOLS[@]}"; do
    name="pre-upgrade-$TARGET_VERSION-$(date -u +%Y%m%d%H%M)"
    log "Backing up $vol as $name"
    new=$(ociv bv backup create --volume-id "$vol" "${R[@]}" --type INCREMENTAL --display-name "$name" \
      --wait-for-state AVAILABLE "${WAIT[@]}" --query 'data.id')
    # Always-Free allows only 5 volume backups total: drop older pre-upgrade backups of this volume.
    oci bv backup list --compartment-id "$COMPART" --volume-id "$vol" "${R[@]}" --all --output json \
      | jq -r --arg new "$new" '.data[] | select((."display-name" | startswith("pre-upgrade-")) and .id != $new
          and ."lifecycle-state" == "AVAILABLE") | .id' \
      | while read -r old; do log "Deleting older pre-upgrade backup $old"; oci bv backup delete --volume-backup-id "$old" "${R[@]}" --force; done
  done
fi

wait_active() {
  for _ in $(seq 1 60); do
    [ "$(cluster_get lifecycle-state)" = "ACTIVE" ] && return 0
    sleep 20
  done; return 1
}

# --- 1) Control plane (non-disruptive) ---
if [ "$CURRENT" != "$TARGET_VERSION" ]; then
  log "Upgrading control plane -> $TARGET_VERSION"
  oci ce cluster update --cluster-id "$OCI_CLUSTER_ID" "${R[@]}" \
    --kubernetes-version "$TARGET_VERSION" --wait-for-state SUCCEEDED "${WAIT[@]}" >/dev/null
  wait_active || die "Control plane did not return ACTIVE; aborting."
fi

# --- 2) Node pool templates (new nodes will boot at TARGET) ---
for pool in "${NODE_POOLS[@]}"; do
  [ "$(ociv ce node-pool get --node-pool-id "$pool" "${R[@]}" --query 'data."kubernetes-version"')" = "$TARGET_VERSION" ] \
    && { log "Node pool template $pool already at $TARGET_VERSION"; continue; }
  log "Updating node pool template $pool -> $TARGET_VERSION"
  # OKE worker images (".../-OKE-1.34.2-1345") pin the k8s version, and OKE rejects a
  # version-only update for them (409 Conflict). Swap to the newest OKE image for TARGET
  # on the same OS line, keeping the boot volume size.
  src=$(oci ce node-pool get --node-pool-id "$pool" "${R[@]}" --query 'data."node-source-details"' --output json)
  img_name=$(ociv compute image get --image-id "$(jq -r '."image-id"' <<<"$src")" "${R[@]}" --query 'data."display-name"')
  extra=()
  if [[ "$img_name" =~ ^(.+)-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]+-OKE- ]]; then
    os_prefix="${BASH_REMATCH[1]}"   # e.g. Oracle-Linux-8.10-aarch64
    new_img=$(oci ce node-pool-options get --node-pool-option-id "$OCI_CLUSTER_ID" "${R[@]}" --output json \
      | jq -r --arg p "$os_prefix-" --arg k "-OKE-${TARGET_VERSION#v}-" \
          '[.data.sources[] | select((."source-name" | startswith($p)) and (."source-name" | contains($k)))]
           | sort_by(."source-name") | last | ."image-id" // empty')
    [ -n "$new_img" ] || die "No $os_prefix OKE image for $TARGET_VERSION in node-pool-options; aborting."
    log "Node image: $img_name -> $new_img"
    extra=(--node-source-details "$(jq -c --arg i "$new_img" \
      '{sourceType:"IMAGE", imageId:$i, bootVolumeSizeInGBs:."boot-volume-size-in-gbs"}' <<<"$src")")
  fi
  oci ce node-pool update --node-pool-id "$pool" "${R[@]}" \
    --kubernetes-version "$TARGET_VERSION" "${extra[@]}" --wait-for-state SUCCEEDED "${WAIT[@]}" --force >/dev/null
done

# --- 3) Cycle nodes one at a time, NO surge (stay within 4-OCPU free cap) ---
WANT=$(desired_nodes)
for pool in "${NODE_POOLS[@]}"; do
  mapfile -t NODE_LINES < <(pool_nodes "$pool")
  for line in "${NODE_LINES[@]}"; do
    read -r NODE_ID NODE_IP NODE_VER <<<"$line"   # kubectl node name == private IP on OKE
    if [ "$NODE_VER" = "$TARGET_VERSION" ]; then log "Node $NODE_IP already at $TARGET_VERSION, skipping"; continue; fi

    log "Draining $NODE_IP"
    kubectl cordon "$NODE_IP"
    if ! kubectl drain "$NODE_IP" --ignore-daemonsets --delete-emptydir-data --timeout=300s; then
      kubectl uncordon "$NODE_IP" || true
      die "Drain of $NODE_IP failed (PodDisruptionBudget?); node uncordoned, aborting before deleting it."
    fi

    log "Deleting node $NODE_IP (pool recreates a replacement at $TARGET_VERSION, no size decrement)"
    oci ce node-pool delete-node --node-pool-id "$pool" --node-id "$NODE_ID" \
      --is-decrement-size false "${R[@]}" --force >/dev/null

    # Done when the old node is gone and the cluster is back to full size, all Ready.
    log "Waiting for replacement node to join and become Ready"
    ok=false
    for _ in $(seq 1 90); do
      if ! kubectl get node "$NODE_IP" >/dev/null 2>&1 \
         && [ "$(ready_node_count)" -ge "$WANT" ] && [ -z "$(not_ready_nodes)" ]; then ok=true; break; fi
      sleep 20
    done
    $ok || die "Replacement node did not become Ready within 30 min; aborting before next node."
  done
done

# --- 4) Final verification ---
log "Verifying cluster health post-upgrade"
kubectl get --raw='/readyz' >/dev/null || die "post-upgrade /readyz failed"
[ "$(cluster_get kubernetes-version)" = "$TARGET_VERSION" ] || die "control plane is not at $TARGET_VERSION"
stale=$(for p in "${NODE_POOLS[@]}"; do pool_nodes "$p"; done | awk -v t="$TARGET_VERSION" '$3 != t {print $2" ("$3")"}')
[ -z "$stale" ] || die "node(s) not at $TARGET_VERSION: $stale"
kubectl get nodes -o wide
echo "Upgrade to $TARGET_VERSION complete."

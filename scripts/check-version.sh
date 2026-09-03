#!/usr/bin/env bash
# ============================================================================
# check-version.sh — classify whether the OKE cluster's Kubernetes version
# is at risk of falling out of OCI's supported window (which starts billing
# $0.10/cluster/hr). Emits a decision to stdout and to $GITHUB_OUTPUT.
#
# Env:
#   OCI_CLUSTER_ID   (required)  OCID of the OKE cluster
#   OCI_REGION       (required)  e.g. il-jerusalem-1
# Requires: oci CLI (authenticated), jq
#
# Outputs (stdout + GITHUB_OUTPUT):
#   status         OK | WARN | URGENT
#   current        current cluster version, e.g. v1.34.2
#   target         next-minor upgrade target, or "" if none/none-needed
#   needs_upgrade  true | false
# ============================================================================
set -euo pipefail

: "${OCI_CLUSTER_ID:?set OCI_CLUSTER_ID}"
: "${OCI_REGION:?set OCI_REGION}"

emit() { # key=value -> stdout and (if in Actions) GITHUB_OUTPUT
  echo "$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >>"$GITHUB_OUTPUT"
}

# minor number from a vX.Y.Z string  ->  X*1000 + Y  (sortable int)
minor_key() { local v="${1#v}"; local maj="${v%%.*}"; local rest="${v#*.}"; local min="${rest%%.*}"; echo $((maj * 1000 + min)); }

CURRENT=$(oci ce cluster get --cluster-id "$OCI_CLUSTER_ID" --region "$OCI_REGION" \
  --query 'data."kubernetes-version"' --raw-output)

# Supported versions, sorted ascending by (major,minor,patch)
mapfile -t SUPPORTED < <(oci ce cluster-options get --cluster-option-id all --region "$OCI_REGION" \
  --query 'data."kubernetes-versions"[]' --raw-output | sort -V)

if [ "${#SUPPORTED[@]}" -eq 0 ]; then echo "ERROR: could not read supported versions" >&2; exit 1; fi

OLDEST="${SUPPORTED[0]}"
CUR_K=$(minor_key "$CURRENT")
OLDEST_K=$(minor_key "$OLDEST")

# Is CURRENT present in the supported list (exact match)?
in_supported=false
for v in "${SUPPORTED[@]}"; do [ "$v" = "$CURRENT" ] && in_supported=true && break; done

# Target = lowest supported version whose minor is exactly one above CURRENT's.
# (OKE upgrades one minor at a time; never skip.)
TARGET=""
NEXT_K=$((CUR_K + 1))
for v in "${SUPPORTED[@]}"; do
  if [ "$(minor_key "$v")" -eq "$NEXT_K" ]; then TARGET="$v"; break; fi
done

if ! $in_supported; then
  STATUS="URGENT"   # already off the supported list — likely already billing
  # fall forward to the lowest supported version at/above current minor
  if [ -z "$TARGET" ]; then
    for v in "${SUPPORTED[@]}"; do [ "$(minor_key "$v")" -ge "$CUR_K" ] && TARGET="$v" && break; done
  fi
elif [ "$CUR_K" -le "$OLDEST_K" ]; then
  STATUS="WARN"     # oldest supported minor — next OCI retirement drops us off
else
  STATUS="OK"
fi

NEEDS=false; [ "$STATUS" != "OK" ] && NEEDS=true
# If we should act but there's no higher minor available, there's nothing to do.
if $NEEDS && [ -z "$TARGET" ]; then NEEDS=false; fi

echo "current=$CURRENT  oldest_supported=$OLDEST  status=$STATUS  target=${TARGET:-none}" >&2
emit "status=$STATUS"
emit "current=$CURRENT"
emit "target=$TARGET"
emit "needs_upgrade=$NEEDS"

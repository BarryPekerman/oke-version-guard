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
#   status         OK | PATCH | WARN | URGENT
#   current        current cluster version, e.g. v1.34.2
#   target         upgrade target (always the HIGHEST patch of the chosen minor),
#                  or "" if none/none-needed
#   needs_upgrade  true | false
# ============================================================================
set -euo pipefail

: "${OCI_CLUSTER_ID:?set OCI_CLUSTER_ID}"
: "${OCI_REGION:?set OCI_REGION}"

emit() { # key=value -> stdout and (if in Actions) GITHUB_OUTPUT
  echo "$1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >>"$GITHUB_OUTPUT"; fi
}

# minor number from a vX.Y.Z string  ->  X*1000 + Y  (sortable int)
# Tolerant of surrounding quotes / leading 'v' by keeping only digits and dots.
minor_key() { local v="${1//[^0-9.]/}"; local maj="${v%%.*}"; local rest="${v#*.}"; local min="${rest%%.*}"; echo $(( ${maj:-0} * 1000 + ${min:-0} )); }
# strip surrounding quotes/whitespace that some OCI CLI builds leave on --raw-output
clean() { local s="${1//\"/}"; s="${s//[[:space:]]/}"; printf '%s' "$s"; }

CURRENT=$(clean "$(oci ce cluster get --cluster-id "$OCI_CLUSTER_ID" --region "$OCI_REGION" \
  --query 'data."kubernetes-version"' --raw-output)")

# Supported versions, sorted ascending by (major,minor,patch).
# Parse with jq (robust) rather than --raw-output, which mishandles arrays on some CLI builds.
mapfile -t SUPPORTED < <(oci ce cluster-options get --cluster-option-id all --region "$OCI_REGION" \
  --query 'data."kubernetes-versions"' --output json | jq -r '.[]' | sort -V)

if [ "${#SUPPORTED[@]}" -eq 0 ]; then echo "ERROR: could not read supported versions" >&2; exit 1; fi

OLDEST="${SUPPORTED[0]}"
CUR_K=$(minor_key "$CURRENT")
OLDEST_K=$(minor_key "$OLDEST")

# Is CURRENT present in the supported list (exact match)?
in_supported=false
for v in "${SUPPORTED[@]}"; do [ "$v" = "$CURRENT" ] && in_supported=true && break; done

# Highest supported patch of a given minor key ("" if that minor isn't offered).
# SUPPORTED is ascending, so the last match wins.
latest_of() { local want="$1" v best=""; for v in "${SUPPORTED[@]}"; do [ "$(minor_key "$v")" -eq "$want" ] && best="$v"; done; printf '%s' "$best"; }

SAME_LATEST=$(latest_of "$CUR_K")          # newest patch of the current minor
NEXT_LATEST=$(latest_of "$((CUR_K + 1))")  # newest patch of the next minor (OKE never skips minors)

TARGET=""
if ! $in_supported; then
  STATUS="URGENT"   # already off the supported list — likely already billing
  # Prefer a patch within the current minor (least disruptive), else step one minor up.
  if [ -n "$SAME_LATEST" ] && [ "$(printf '%s\n%s\n' "$CURRENT" "$SAME_LATEST" | sort -V | tail -1)" = "$SAME_LATEST" ]; then
    TARGET="$SAME_LATEST"
  else
    TARGET="$NEXT_LATEST"
  fi
elif [ "$CUR_K" -le "$OLDEST_K" ]; then
  STATUS="WARN"     # oldest supported minor — next OCI retirement drops us off
  TARGET="$NEXT_LATEST"
elif [ "$CURRENT" != "$SAME_LATEST" ]; then
  STATUS="PATCH"    # supported, but OCI deprecates old patches — move to the newest one
  TARGET="$SAME_LATEST"
else
  STATUS="OK"
fi

NEEDS=false; [ "$STATUS" != "OK" ] && NEEDS=true
# If we should act but no target version is offered, there's nothing to do.
if $NEEDS && [ -z "$TARGET" ]; then NEEDS=false; fi

echo "current=$CURRENT  oldest_supported=$OLDEST  status=$STATUS  target=${TARGET:-none}" >&2
emit "status=$STATUS"
emit "current=$CURRENT"
emit "target=$TARGET"
emit "needs_upgrade=$NEEDS"

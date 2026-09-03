#!/usr/bin/env bash
# ============================================================================
# oci-auth.sh — exchange a GitHub Actions OIDC token for a short-lived OCI
# session token (UPST), so the OCI CLI can authenticate WITHOUT a stored key.
#
# Env (from the workflow):
#   OCI_DOMAIN_URL   identity domain base, e.g. https://idcs-xxxx.identity.oraclecloud.com
#   OCI_CLIENT_ID    client_id of the domain OAuth client tied to the trust
#   OCI_REGION       e.g. il-jerusalem-1
#   OIDC_AUDIENCE    audience to mint the GitHub token with (default: OCI_DOMAIN_URL)
#   ACTIONS_ID_TOKEN_REQUEST_URL / _TOKEN   (auto-provided when id-token: write)
# Requires: curl, jq, openssl, oci CLI
#
# On success: writes ~/.oci/upst_session token + key and prints the exports the
# job should eval so subsequent `oci` calls use --auth security_token.
#
# NOTE: OCI's GitHub-OIDC token exchange is domain-specific. The request shape
# below follows Oracle's documented UPST token-exchange flow; the OAuth client
# (OCI_CLIENT_ID) and audience must match what the identity domain expects.
# This is the one piece to validate end-to-end on first run (see README).
# ============================================================================
set -euo pipefail
: "${OCI_DOMAIN_URL:?}" ; : "${OCI_CLIENT_ID:?}" ; : "${OCI_REGION:?}"
AUD="${OIDC_AUDIENCE:-$OCI_DOMAIN_URL}"
mkdir -p "$HOME/.oci"

# 1) Ephemeral RSA session keypair; OCI binds the UPST to this public key.
openssl genrsa -out "$HOME/.oci/upst_session.pem" 2048 2>/dev/null
openssl rsa -in "$HOME/.oci/upst_session.pem" -pubout -out "$HOME/.oci/upst_session_public.pem" 2>/dev/null
PUB_B64=$(grep -v 'PUBLIC KEY' "$HOME/.oci/upst_session_public.pem" | tr -d '\n')

# 2) Ask GitHub for an OIDC JWT scoped to our audience.
GH_JWT=$(curl -sS -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUD}" | jq -r '.value')
[ -n "$GH_JWT" ] && [ "$GH_JWT" != "null" ] || { echo "Failed to obtain GitHub OIDC token" >&2; exit 1; }

# 3) Exchange the GitHub JWT for an OCI UPST at the domain token endpoint.
RESP=$(curl -sS -X POST "${OCI_DOMAIN_URL}/oauth2/v1/token" \
  -u "${OCI_CLIENT_ID}:" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "requested_token_type=urn:oci:token-type:oci-upst" \
  --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "subject_token=${GH_JWT}" \
  --data-urlencode "public_key=${PUB_B64}")

UPST=$(echo "$RESP" | jq -r '.token // .access_token // empty')
[ -n "$UPST" ] || { echo "Token exchange failed: $RESP" >&2; exit 1; }
printf '%s' "$UPST" > "$HOME/.oci/upst_session.token"

# 4) Emit exports for the OCI CLI to use the session token.
echo "OCI_CLI_AUTH=security_token"
echo "OCI_CLI_REGION=${OCI_REGION}"
echo "export OCI_CLI_AUTH=security_token OCI_CLI_REGION=${OCI_REGION}"
cat > "$HOME/.oci/config" <<EOF
[DEFAULT]
region=${OCI_REGION}
security_token_file=$HOME/.oci/upst_session.token
key_file=$HOME/.oci/upst_session.pem
EOF
echo "OCI session token ready (~/.oci/upst_session.token)" >&2

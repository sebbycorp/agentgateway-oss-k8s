#!/usr/bin/env bash
# Creates the Codex profile that sends Codex through agentgateway.
#
#   scripts/codex-profile.sh                              # gateway without sign-in
#   TENANT_ID=... APP_ID=... scripts/codex-profile.sh     # gateway with Entra ID sign-in
#
# INGRESS_GW_ADDRESS defaults to localhost:8080 (kind-config.yaml).
# Writes ~/.codex/agentgateway.config.toml; an existing file is kept as .bak.
# Your ~/.codex/config.toml is not touched. See codex/README.md.
set -euo pipefail

PROFILE="${PROFILE:-$HOME/.codex/agentgateway.config.toml}"
ADDR="${INGRESS_GW_ADDRESS:-localhost:8080}"

mkdir -p "$(dirname "$PROFILE")"
[ -f "$PROFILE" ] && cp "$PROFILE" "$PROFILE.bak"

cat > "$PROFILE" <<TOML
model = "gpt-oss-120b"
model_provider = "agentgateway"

[model_providers.agentgateway]
name = "agentgateway"
base_url = "http://${ADDR}/v1"
wire_api = "responses"
TOML

if [ -n "${TENANT_ID:-}" ] && [ -n "${APP_ID:-}" ]; then
  cat >> "$PROFILE" <<TOML

# Codex signs you in with Microsoft Entra ID before it calls the gateway.
[model_providers.agentgateway.gateway_oauth]
authorization_url = "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/authorize"
token_url = "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"
client_id = "${APP_ID}"
scopes = ["api://${APP_ID}/access", "offline_access"]

# Sign in once with: codex --profile agentgateway mcp login solo-search
TOML
  auth="Entra ID sign-in"
else
  auth="none"
fi

cat >> "$PROFILE" <<TOML

[mcp_servers.solo-search]
url = "http://${ADDR}/mcp"
TOML

echo "Profile:  $PROFILE"
echo "Gateway:  http://$ADDR"
echo "Sign-in:  $auth"
echo "Run:      codex --profile agentgateway"

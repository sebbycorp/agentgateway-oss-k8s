#!/usr/bin/env bash
# Creates or refreshes an isolated Claude Code profile that sends everything
# through agentgateway. Safe to rerun; other settings in the profile are kept.
#
#   scripts/claude-code-profile.sh                              # gateway without sign-in
#   TENANT_ID=... APP_ID=... scripts/claude-code-profile.sh     # gateway with Entra ID sign-in
#
# INGRESS_GW_ADDRESS defaults to localhost:8080 (kind-config.yaml).
# Your normal ~/.claude is not touched. See claude-code/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE_DIR="${PROFILE_DIR:-$HOME/.claude-agentgateway}"
BASE_URL="http://${INGRESS_GW_ADDRESS:-localhost:8080}"

mkdir -p "$PROFILE_DIR/bin"
install -m 755 claude-code/claude-agw "$PROFILE_DIR/bin/claude-agw"
settings="$PROFILE_DIR/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"

# Merge into settings.json.
tmp=$(mktemp)
jq --arg url "$BASE_URL" '.env = ((.env // {}) + {
  ANTHROPIC_BASE_URL: $url,
  ANTHROPIC_MODEL: "claude-sonnet-5-5",
  ANTHROPIC_DEFAULT_OPUS_MODEL: "claude-opus-5-5",
  ANTHROPIC_DEFAULT_SONNET_MODEL: "claude-sonnet-5-5",
  ANTHROPIC_DEFAULT_HAIKU_MODEL: "claude-haiku-5-5",
  CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY: "1",
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
})' "$settings" > "$tmp" && mv "$tmp" "$settings"

export CLAUDE_CONFIG_DIR="$PROFILE_DIR"
claude mcp remove --scope user solo-search >/dev/null 2>&1 || true

if [ -n "${TENANT_ID:-}" ] && [ -n "${APP_ID:-}" ]; then
  # Entra ID: Claude Code runs entra-token.py to get the token for the model and the MCP server.
  install -m 755 claude-code/entra-token.py "$PROFILE_DIR/entra-token.py"
  jq -n --arg t "$TENANT_ID" --arg a "$APP_ID" '{tenantId: $t, appId: $a}' > "$PROFILE_DIR/entra.json"
  tmp=$(mktemp)
  jq --arg helper "$PROFILE_DIR/entra-token.py" \
    'del(.env.ANTHROPIC_AUTH_TOKEN) | .apiKeyHelper = $helper' "$settings" > "$tmp" && mv "$tmp" "$settings"
  claude mcp add-json --scope user solo-search \
    "$(jq -nc --arg url "$BASE_URL/mcp" --arg h "$PROFILE_DIR/entra-token.py headers" \
      '{type: "http", url: $url, headersHelper: $h}')" >/dev/null
  auth="Entra ID sign-in"
else
  # No sign-in: Claude Code still needs some token value or it shows its login screen.
  rm -f "$PROFILE_DIR/entra.json" "$PROFILE_DIR/entra-token.py" "$PROFILE_DIR/entra-token.json"
  tmp=$(mktemp)
  jq 'del(.apiKeyHelper) | .env.ANTHROPIC_AUTH_TOKEN = "none-the-gateway-holds-the-key"' \
    "$settings" > "$tmp" && mv "$tmp" "$settings"
  claude mcp add --transport http --scope user solo-search "$BASE_URL/mcp" >/dev/null
  auth="none"
fi

echo "Profile:  $PROFILE_DIR"
echo "Gateway:  $BASE_URL"
echo "Sign-in:  $auth"
echo "Run:      $PROFILE_DIR/bin/claude-agw"

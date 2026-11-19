#!/usr/bin/env bash
# Creates the Microsoft Entra ID objects for the optional sign-in section of the README:
#   - a security group (default name: codex) with you as a member
#   - an app registration that represents the gateway (default name: agentgateway-oss-codex)
# Safe to rerun: existing objects with the same name are reused.
# Needs: az login as a user who may create groups and app registrations.
set -euo pipefail

GROUP_NAME="${GROUP_NAME:-codex}"
APP_NAME="${APP_NAME:-agentgateway-oss-codex}"
AZ_CLI_CLIENT_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"   # Microsoft's fixed client ID for the Azure CLI

TENANT_ID=$(az account show --query tenantId -o tsv)
ME=$(az ad signed-in-user show --query id -o tsv)

# --- group ---------------------------------------------------------------
GROUP_ID=$(az ad group list --filter "displayName eq '$GROUP_NAME'" --query '[0].id' -o tsv)
if [ -z "$GROUP_ID" ]; then
  GROUP_ID=$(az ad group create --display-name "$GROUP_NAME" --mail-nickname "$GROUP_NAME" \
    --description "Access to LLMs and MCP servers through agentgateway" --query id -o tsv)
fi
if [ "$(az ad group member check --group "$GROUP_ID" --member-id "$ME" --query value -o tsv)" != "true" ]; then
  az ad group member add --group "$GROUP_ID" --member-id "$ME"
fi

# --- app registration ----------------------------------------------------
APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)
fi
OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)

# Application ID URI + put the user's security groups in the token.
az ad app update --id "$APP_ID" --identifier-uris "api://$APP_ID" --set groupMembershipClaims=SecurityGroup

# Expose one scope ("access") and issue v2.0 tokens.
SCOPE_ID=$(az ad app show --id "$APP_ID" --query "api.oauth2PermissionScopes[?value=='access'].id | [0]" -o tsv)
if [ -z "$SCOPE_ID" ]; then
  SCOPE_ID=$(uuidgen | tr 'A-Z' 'a-z')
  az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
    --headers 'Content-Type=application/json' --body "{
      \"api\": {
        \"requestedAccessTokenVersion\": 2,
        \"oauth2PermissionScopes\": [{
          \"id\": \"$SCOPE_ID\", \"value\": \"access\", \"type\": \"User\", \"isEnabled\": true,
          \"adminConsentDisplayName\": \"Access agentgateway\",
          \"adminConsentDescription\": \"Call LLMs and MCP servers through agentgateway\",
          \"userConsentDisplayName\": \"Access agentgateway\",
          \"userConsentDescription\": \"Call LLMs and MCP servers through agentgateway\"
        }]
      }
    }"
fi

# Let the Azure CLI request that scope without a consent prompt.
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  --headers 'Content-Type=application/json' --body "{
    \"api\": { \"preAuthorizedApplications\": [{
      \"appId\": \"$AZ_CLI_CLIENT_ID\", \"delegatedPermissionIds\": [\"$SCOPE_ID\"]
    }] }
  }"

# Let Codex sign users in: public client (no secret) with loopback redirect URIs.
# Existing redirect URIs (e.g. the MCP callback from README step H) are kept.
EXISTING=$(az ad app show --id "$APP_ID" --query 'publicClient.redirectUris' -o json)
URIS=$(python3 -c 'import json,sys; print(json.dumps(sorted(set(json.loads(sys.argv[1]) + ["http://127.0.0.1/callback", "http://localhost/callback"]))))' "$EXISTING")
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  --headers 'Content-Type=application/json' \
  --body "{\"isFallbackPublicClient\": true, \"publicClient\": {\"redirectUris\": $URIS}}"

# The app needs a service principal in the tenant before tokens can be issued for it.
if [ -z "$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv)" ]; then
  az ad sp create --id "$APP_ID" --query id -o tsv >/dev/null
fi

cat <<EOF

Done. Use these in the README steps:

export TENANT_ID=$TENANT_ID
export APP_ID=$APP_ID
export GROUP_ID=$GROUP_ID
OBJECT_ID=$OBJECT_ID
EOF

#!/usr/bin/env bash
# Builds the whole setup in one go: kind cluster with the gateway on localhost:8080,
# agentgateway, Postgres, all models, the MCP server and (optionally) Entra ID sign-in.
# Same commands as the README steps. Safe to rerun on an existing cluster.
#
#   export BEDROCK_API_KEY=...
#   scripts/deploy.sh
#
# Entra ID sign-in is applied when TENANT_ID, APP_ID and GROUP_ID are set
# (scripts/entra-setup.sh prints them).
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=agentgateway-codex
CTX=kind-$CLUSTER
NS=agentgateway-system
: "${BEDROCK_API_KEY:?export BEDROCK_API_KEY first}"
k() { kubectl --context "$CTX" "$@"; }

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --config kind-config.yaml

k apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml >/dev/null
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --kube-context "$CTX" --create-namespace --namespace $NS --version v1.7.0 >/dev/null
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --kube-context "$CTX" --namespace $NS --version v1.7.0 \
  --set controller.image.pullPolicy=Always --wait >/dev/null

# Request-log database
k -n $NS get secret agentgateway-db >/dev/null 2>&1 || \
  k -n $NS create secret generic agentgateway-db --from-literal=password="$(openssl rand -hex 24)"
k apply -f k8s/03-postgres.yaml
k -n $NS rollout status statefulset/agentgateway-db --timeout=300s
PG_PASSWORD=$(k -n $NS get secret agentgateway-db -o jsonpath='{.data.password}' | base64 -d)
sed "s/\${PG_PASSWORD}/$PG_PASSWORD/" k8s/04-gateway-parameters.yaml | k apply -f -

# Gateway, Bedrock key, models, MCP server, fixed port
k apply -f k8s/01-gateway.yaml
k -n $NS create secret generic bedrock-secret --from-literal=Authorization="$BEDROCK_API_KEY" \
  --dry-run=client -o yaml | k apply -f -
k apply -f k8s/02-model-bedrock-openai.yaml -f k8s/07-more-bedrock-models.yaml \
  -f k8s/08-claude-code-models.yaml -f k8s/05-mcp-solo-search.yaml -f k8s/09-fixed-port.yaml

# Optional: Entra ID sign-in, with the sign-in name in the request logs
if [ -n "${TENANT_ID:-}" ] && [ -n "${APP_ID:-}" ] && [ -n "${GROUP_ID:-}" ]; then
  sed -e "s/\${TENANT_ID}/$TENANT_ID/g" -e "s/\${APP_ID}/$APP_ID/g" -e "s/\${GROUP_ID}/$GROUP_ID/g" \
    k8s/06-entra-auth.yaml | k apply -f -
  k -n $NS patch agentgatewayparameters agentgateway-proxy-params --type merge \
    -p '{"spec":{"rawConfig":{"config":{"standardAttributes":{"user":"jwt.preferred_username"}}}}}'
  echo "Entra ID sign-in: on"
else
  echo "Entra ID sign-in: off (TENANT_ID, APP_ID, GROUP_ID not set)"
fi

until k -n $NS get deploy agentgateway-proxy >/dev/null 2>&1; do sleep 2; done
k -n $NS rollout status deploy/agentgateway-proxy --timeout=300s
echo "Gateway: http://localhost:8080"

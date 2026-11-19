# Codex CLI through agentgateway

Runs OpenAI Codex CLI against the gateway from the [main README](../README.md). The gateway holds the
Bedrock API key; Codex has no key. The settings go in a Codex profile, a separate file, so your existing
`~/.codex/config.toml` is untouched.

```
codex --profile agentgateway ──► agentgateway on localhost:8080 ──► Amazon Bedrock us-east-2
 (no API key)   POST /v1/responses        └─ /mcp ──► https://search.solo.io/mcp
```

Tested with Codex CLI 0.170.0 and agentgateway v1.7.0.

## Before you start

The gateway is built (main README, Option A or B) and answers:

```sh
export CTX=kind-agentgateway-codex
export INGRESS_GW_ADDRESS=localhost:8080
curl -s "http://$INGRESS_GW_ADDRESS/v1/models" | jq -r '.data[].id'      # lists gpt-oss-120b
```

Then create the profile with **Option A** (script) or **Option B** (by hand). They produce the same file.

## Option A — Create the profile with the script

```sh
scripts/codex-profile.sh
```

[`scripts/codex-profile.sh`](../scripts/codex-profile.sh) writes `~/.codex/agentgateway.config.toml` with
the model provider and the `solo-search` MCP server. If the file exists, the old one is kept as
`agentgateway.config.toml.bak`. Continue with [Run it](#run-it).

## Option B — Create the profile by hand

### Step 1 — Write the profile

Create a Codex profile. This is a separate file, so your existing `~/.codex/config.toml` is untouched:

```sh
export AGENTGATEWAY_BASE_URL="http://${INGRESS_GW_ADDRESS}/v1"

cat > ~/.codex/agentgateway.config.toml <<EOF
model = "gpt-oss-120b"
model_provider = "agentgateway"

[model_providers.agentgateway]
name = "OpenAI via agentgateway"
base_url = "${AGENTGATEWAY_BASE_URL}"
wire_api = "responses"
EOF
```

- The `/v1` suffix is required — Codex posts to `<base_url>/responses`.
- `wire_api = "responses"` is required — Codex uses the Responses API, not chat completions.
- No `env_key` is set, so Codex sends no credential. The gateway supplies the Bedrock key.
- `model` must be the name the gateway publishes.

### Step 2 — Add the MCP server

The gateway exposes `https://search.solo.io/mcp` at `/mcp` (main README, Step 10). Append it to the
profile:

```sh
cat >> ~/.codex/agentgateway.config.toml <<EOF

[mcp_servers.solo-search]
url = "http://${INGRESS_GW_ADDRESS}/mcp"
EOF
```

## Run it

```sh
codex --profile agentgateway                    # interactive
codex exec --profile agentgateway "Hello"       # one-shot
```

One-off alternative without a profile file:

```sh
codex -c model_provider='"agentgateway"' \
  -c model_providers.agentgateway.name='"OpenAI via agentgateway"' \
  -c model_providers.agentgateway.base_url="\"${AGENTGATEWAY_BASE_URL}\"" \
  -c model_providers.agentgateway.wire_api='"responses"'
```

## Verify Codex traffic goes through the gateway

```sh
codex exec --profile agentgateway --skip-git-repo-check "Reply with exactly: hello from agentgateway"

kubectl --context $CTX logs deployment/agentgateway-proxy -n agentgateway-system --since=5m \
  | grep 'http.path=/v1/responses' | tail -n 5
```

A successful entry looks like this (trimmed):

```
info request gateway=agentgateway-system/agentgateway-proxy route=internal/llm:request
  endpoint=bedrock-runtime.us-east-2.amazonaws.com:443 http.method=POST http.path=/v1/responses
  http.status=200 protocol=llm gen_ai.provider.name=aws.bedrock
  gen_ai.request.model=openai.gpt-oss-120b-1:0 agw.ai.original_model=gpt-oss-120b
```

Test the MCP server:

```sh
codex exec --profile agentgateway --skip-git-repo-check \
  "Use the solo-search MCP search tool to look up: AgentgatewayModel. Summarize the top result."
```

The calls also show on the UI Logs and Analytics pages (main README, Step 11).

## Other models

Apply [`k8s/07-more-bedrock-models.yaml`](../k8s/07-more-bedrock-models.yaml) (main README, Step 7; the
deploy script already does) and pick a model with `-m`:

```sh
codex --profile agentgateway -m claude-haiku-4-5      # or: -m gpt-oss-20b
```

| Name in Codex | Bedrock model | Result with Codex |
|---|---|---|
| `gpt-oss-120b` | `openai.gpt-oss-120b-1:0` | works: chat, shell commands, MCP tools |
| `gpt-oss-20b` | `openai.gpt-oss-20b-1:0` | works: chat, shell commands, MCP tools. Sometimes prints its reasoning in front of the answer |
| `claude-haiku-4-5` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | works: chat, shell commands, MCP tools, after the change below |

**Claude models need two Codex tools turned off if you have the ChatGPT desktop app installed.** The app
adds two JavaScript REPL tools to Codex (`cua_repl` from the `unified-computer-use` plugin, and
`node_repl`). Their schemas use a top-level `oneOf`, which Claude on Bedrock rejects for the whole
request:

```
HTTP 400: tools.12.custom.input_schema: input_schema does not support oneOf, allOf, or anyOf at the top level
```

Turn them off for the gateway profile only. Add each block only if `codex mcp list` shows that server,
otherwise Codex refuses to load the profile:

```sh
cat >> ~/.codex/agentgateway.config.toml <<'EOF'

# Claude on Bedrock rejects the schema of these two desktop-app tools.
[plugins."unified-computer-use@openai-bundled"]
enabled = false

[mcp_servers.node_repl]
enabled = false
EOF
```

Any other MCP tool whose schema has `oneOf`, `anyOf` or `allOf` at the top level causes the same error
with Claude models. The OpenAI models on Bedrock accept them.

## Entra ID sign-in

To make Codex sign in with Microsoft Entra ID before it can use the gateway, follow
**[entra-id/README.md](../entra-id/README.md)**. With `TENANT_ID` and `APP_ID` set,
`scripts/codex-profile.sh` writes the profile from Step 6 of that guide for you.

## Things to know

- **`codex exec` from a script** waits on stdin if it is not a TTY; add `</dev/null`.
- **ChatGPT desktop app:** the docs cover this by replacing `~/.codex/config.toml`. Not done here, because
  that file holds existing plugin/MCP settings. To do it, merge the four keys from the profile into that file
  (back it up first) and restart the app.

## Cleanup

```sh
rm ~/.codex/agentgateway.config.toml
```

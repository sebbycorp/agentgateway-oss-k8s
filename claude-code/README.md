# Claude Code through agentgateway

Runs Claude Code against the same gateway as Codex, using Claude models on Amazon Bedrock. The gateway
holds the Bedrock API key; Claude Code has no key and no Anthropic login. Optionally, the gateway asks
for a Microsoft Entra ID sign-in first.

Claude Code has no named profiles, so this uses a separate configuration directory
(`CLAUDE_CONFIG_DIR`). Settings, history, MCP servers and credentials in `~/.claude-agentgateway` are
separate from your normal `~/.claude`, which is not touched.

```
claude-agw ──► claude (CLAUDE_CONFIG_DIR=~/.claude-agentgateway)
                 │  POST /v1/messages          (Entra token, if sign-in is on)
                 ▼
        agentgateway on localhost:8080 ──► Amazon Bedrock us-east-2 (gateway adds the key)
                 └─ /mcp ──► https://search.solo.io/mcp
```

Tested with Claude Code 2.1.328 and agentgateway v1.7.0.

Steps 2 and 5 each have two paths side by side: **Option A** uses a script, **Option B** does the same
thing by hand.

| File | What it is |
|---|---|
| [`k8s/08-claude-code-models.yaml`](../k8s/08-claude-code-models.yaml) | Claude Opus, Sonnet and Haiku 5.5 on Bedrock |
| [`scripts/claude-code-profile.sh`](../scripts/claude-code-profile.sh) | Creates the Claude Code profile (Option A) |
| [`claude-agw`](claude-agw) | Launcher: signs you in if needed, then starts Claude Code with the profile |
| [`entra-token.py`](entra-token.py) | Entra ID sign-in and token refresh |

## Step 1 — Build the gateway with the Claude models

Build the gateway from the [main README](../README.md), with its script (Option A there) or by hand
(Option B there). Claude Code needs the three models in
[`k8s/08-claude-code-models.yaml`](../k8s/08-claude-code-models.yaml), published under the names it
asks for. The deploy script applies that file; by hand it is the last command of Step 7:

```sh
export CTX=kind-agentgateway-codex
kubectl --context $CTX apply -f k8s/08-claude-code-models.yaml
```

| Name Claude Code sends | Bedrock model | `/model` alias |
|---|---|---|
| `claude-opus-5-5` | `us.anthropic.claude-opus-5-5` | `opus` |
| `claude-sonnet-5-5` | `us.anthropic.claude-sonnet-5-5` | `sonnet` (default) |
| `claude-haiku-5-5` | `us.anthropic.claude-haiku-5-5` | `haiku` (also background tasks) |

No other gateway change is needed for Claude Code. An `AgentgatewayModel` already accepts the Anthropic
Messages API at `/v1/messages` and translates it for Bedrock.

Test without Claude Code:

```sh
curl -s localhost:8080/v1/messages -H content-type:application/json -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-sonnet-5-5","max_tokens":50,"messages":[{"role":"user","content":"Say hi"}]}' \
  | jq -r '.content[0].text'
```

## Step 2 — Create the profile

Both options produce the same profile in `~/.claude-agentgateway`.

### Option A — With the script

```sh
scripts/claude-code-profile.sh
```

It writes `settings.json`, installs the `claude-agw` launcher, and adds the `solo-search` MCP server.
Safe to rerun; other settings in the profile are kept.

### Option B — By hand

```sh
P=$HOME/.claude-agentgateway
mkdir -p $P/bin

# 1. Settings: where the gateway is and which models to use
cat > $P/settings.json <<'EOF'
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8080",
    "ANTHROPIC_AUTH_TOKEN": "none-the-gateway-holds-the-key",
    "ANTHROPIC_MODEL": "claude-sonnet-5-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-5-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-5-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-5-5",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
EOF

# 2. The MCP server on the gateway, stored in the profile's own .claude.json
CLAUDE_CONFIG_DIR=$P claude mcp add --transport http --scope user solo-search http://localhost:8080/mcp

# 3. The launcher
install -m 755 claude-code/claude-agw $P/bin/claude-agw
```

### Both options — add the alias

```sh
echo "alias claude-agw='\$HOME/.claude-agentgateway/bin/claude-agw'" >> ~/.zshrc && source ~/.zshrc
```

### What the settings mean

- `ANTHROPIC_BASE_URL` has no `/v1` — Claude Code adds `/v1/messages` itself.
- `ANTHROPIC_AUTH_TOKEN` is a placeholder. Claude Code needs some value or it shows the login screen;
  the gateway ignores it and adds the Bedrock key.
- The three `ANTHROPIC_DEFAULT_*_MODEL` values pin what `opus`, `sonnet` and `haiku` mean, so a Claude
  Code update cannot start asking for a model the gateway does not publish.
- `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` makes `/model` list what the gateway serves at `/v1/models`.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` turns off telemetry and auto-update calls that would go to
  Anthropic directly.

## Step 3 — Run it

```sh
claude-agw                    # interactive
claude-agw -p "Hello"         # one-shot
claude-agw --model opus       # pick a model
```

`claude-agw` passes its arguments to `claude`. Without the launcher, the same thing is
`CLAUDE_CONFIG_DIR=~/.claude-agentgateway claude`.

The first interactive start asks for a colour theme (it is a new profile). It does not ask for an
Anthropic login.

## Step 4 — Verify traffic goes through the gateway

```sh
export CTX=kind-agentgateway-codex
claude-agw -p "Reply with exactly: hello from agentgateway"

kubectl --context $CTX logs deployment/agentgateway-proxy -n agentgateway-system --since=5m \
  | grep 'http.path=/v1/messages' | tail -n 3
```

A successful entry looks like this (trimmed):

```
info request route=internal/llm:request endpoint=bedrock-runtime.us-east-2.amazonaws.com:443
  http.method=POST http.path=/v1/messages?beta=true http.status=200 protocol=llm
  gen_ai.provider.name=aws.bedrock gen_ai.request.model=us.anthropic.claude-sonnet-5-5
  agw.ai.original_model=claude-sonnet-5-5 gen_ai.usage.cache_read.input_tokens=13569
```

The calls also show on the UI Logs and Analytics pages (main README, Step 11).

## Step 5 — Optional: Entra ID sign-in

With this on, the gateway answers 401 without a valid Entra token and 403 unless you are in the allowed
group, for the models and the MCP server. `claude-agw` opens the Microsoft sign-in page when you have
no usable sign-in, and the Logs page shows who made each call.

**1. Create the Entra group and app registration** (once per tenant; needs `az login`).

Option A — with the script. It reuses the objects if they exist and prints three `export` lines; run
those:

```sh
scripts/entra-setup.sh
export TENANT_ID=... APP_ID=... GROUP_ID=...
```

Option B — by hand: Steps 1–3 of the [Entra guide](../entra-id/README.md), which also explain each
setting.

**2. Turn it on at the gateway.**

Option A — with the script. With the three variables set, `deploy.sh` applies
[`k8s/06-entra-auth.yaml`](../k8s/06-entra-auth.yaml) and puts the sign-in name in the request logs:

```sh
scripts/deploy.sh
```

Option B — by hand (Steps 4 and 10 of the Entra guide):

```sh
sed -e "s/\${TENANT_ID}/$TENANT_ID/g" -e "s/\${APP_ID}/$APP_ID/g" -e "s/\${GROUP_ID}/$GROUP_ID/g" \
  k8s/06-entra-auth.yaml | kubectl --context $CTX apply -f -
kubectl --context $CTX -n agentgateway-system patch agentgatewayparameters agentgateway-proxy-params \
  --type merge -p '{"spec":{"rawConfig":{"config":{"standardAttributes":{"user":"jwt.preferred_username"}}}}}'
kubectl --context $CTX -n agentgateway-system rollout status deploy/agentgateway-proxy
```

Either way, the gateway now rejects calls without a token:

```sh
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8080/v1/messages    # 401
```

**3. Switch the profile to Entra sign-in.**

Option A — with the script (with `TENANT_ID` and `APP_ID` still set):

```sh
scripts/claude-code-profile.sh
```

Option B — by hand:

```sh
P=$HOME/.claude-agentgateway

# 1. The sign-in helper and the IDs it needs (neither ID is a secret)
install -m 755 claude-code/entra-token.py $P/entra-token.py
echo "{\"tenantId\": \"$TENANT_ID\", \"appId\": \"$APP_ID\"}" > $P/entra.json

# 2. Settings: drop the placeholder token, run the helper instead
jq --arg helper "$P/entra-token.py" 'del(.env.ANTHROPIC_AUTH_TOKEN) | .apiKeyHelper = $helper' \
  $P/settings.json > $P/settings.json.new && mv $P/settings.json.new $P/settings.json

# 3. MCP server: send the same token
CLAUDE_CONFIG_DIR=$P claude mcp remove --scope user solo-search
CLAUDE_CONFIG_DIR=$P claude mcp add-json --scope user solo-search \
  "{\"type\": \"http\", \"url\": \"http://localhost:8080/mcp\", \"headersHelper\": \"$P/entra-token.py headers\"}"
```

Either way, three things change in the profile:

- `settings.json` gets `"apiKeyHelper": "~/.claude-agentgateway/entra-token.py"` and loses
  `ANTHROPIC_AUTH_TOKEN`. Claude Code runs the helper and sends its output as the bearer token.
- The MCP server gets `"headersHelper": "~/.claude-agentgateway/entra-token.py headers"`, so the same
  sign-in covers `/mcp`. There is no second sign-in and no extra redirect URI to register.
- `entra.json` holds the tenant and app IDs.

**4. Sign in and use it:**

```sh
claude-agw            # opens the Microsoft sign-in page the first time, then starts Claude Code
```

How the sign-in works: [`entra-token.py`](entra-token.py) does a browser sign-in with PKCE against
your app registration (a public client, no secret), using the `http://localhost/callback` redirect URI
that `entra-setup.sh` registers. It keeps the access and refresh token in
`~/.claude-agentgateway/entra-token.json`, readable only by you, and refreshes the access token when
under 10 minutes are left. Claude Code asks the helper again every 5 minutes and after a 401.

| Command | What it does |
|---|---|
| `claude-agw login` | Sign in again (for example as another user) |
| `claude-agw logout` | Forget the sign-in. The next `claude-agw` opens the sign-in page |

Check who the gateway saw:

```sh
kubectl --context $CTX -n agentgateway-system exec agentgateway-db-0 -- \
  psql -U agentgateway -d agentgateway -c \
  'select started_at, http_status, agentgateway_user, gen_ai_request_model from request_logs order by started_at desc limit 5'
```

To turn sign-in off again: delete the two policies (Entra guide, "Turn it off") and redo Step 2 with
either option (run the script without `TENANT_ID` and `APP_ID` set).

## Things to know

- **Prompt caching works.** Claude Code's cache markers pass through to Bedrock (see
  `cache_read.input_tokens` in the log above).
- **Token counting returns 403** unless the IAM identity behind the Bedrock API key allows
  `bedrock:CountTokens`. Claude Code falls back to an estimate; nothing breaks.
- **Claude Fable 5.2 is not published.** On the account used here Bedrock answers
  `data retention mode 'default' is not available for this model`. Once the account has access, copy a
  block in `k8s/08-claude-code-models.yaml` and use `claude-fable-5-2`.
- **The OpenAI models do not work from Claude Code.** `--model gpt-oss-120b` fails: Bedrock rejects
  Claude Code's prompt-cache markers and its `thinking` setting for those models. Use Codex for them.
- **Only `claude-agw` opens the sign-in page.** If the sign-in expires in the middle of a long session
  (the refresh token is revoked or unused for 90 days), calls fail with
  `Not signed in to Entra ID`. Run `claude-agw login` in another terminal; the session then continues.
- **Group changes take up to an hour**, because membership is read when the token is issued.
- **The refresh token is stored in a plain file** with `0600` permissions, not in the macOS Keychain.
- **Codex on the same gateway.** See [codex/README.md](../codex/README.md). With Entra on, follow the
  [Entra guide](../entra-id/README.md) from Step 6.

## Cleanup

```sh
rm -rf ~/.claude-agentgateway                       # profile, sign-in, history
kind delete cluster --name agentgateway-codex       # also deletes the Postgres data
# and remove the claude-agw alias from ~/.zshrc
```

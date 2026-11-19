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

| File | What it is |
|---|---|
| [`kind-config.yaml`](../kind-config.yaml), [`k8s/09-fixed-port.yaml`](../k8s/09-fixed-port.yaml) | Gateway on a fixed `localhost:8080` |
| [`k8s/08-claude-code-models.yaml`](../k8s/08-claude-code-models.yaml) | Claude Opus, Sonnet and Haiku 5.5 on Bedrock |
| [`scripts/deploy.sh`](../scripts/deploy.sh) | Builds the cluster and gateway in one go |
| [`scripts/claude-code-profile.sh`](../scripts/claude-code-profile.sh) | Creates the Claude Code profile |
| [`claude-agw`](claude-agw) | Launcher: signs you in if needed, then starts Claude Code with the profile |
| [`entra-token.py`](entra-token.py) | Entra ID sign-in and token refresh |

## Step 1 — Deploy the gateway

You need Docker, `kind`, `kubectl`, `helm`, `jq`, `openssl` and `claude` on your `PATH`.

```sh
export BEDROCK_API_KEY='<your Bedrock API key>'
scripts/deploy.sh
```

This runs the steps of the [main README](../README.md) with two differences:

- **Fixed port.** The cluster is created from `kind-config.yaml`, which maps `localhost:8080` to node
  port 30080, and `k8s/09-fixed-port.yaml` publishes the proxy there. cloud-provider-kind is not
  needed, the address never changes, and it listens on `127.0.0.1` only.
- **Claude models.** `k8s/08-claude-code-models.yaml` publishes three models under the names Claude
  Code asks for:

  | Name Claude Code sends | Bedrock model | `/model` alias |
  |---|---|---|
  | `claude-opus-5-5` | `us.anthropic.claude-opus-5-5` | `opus` |
  | `claude-sonnet-5-5` | `us.anthropic.claude-sonnet-5-5` | `sonnet` (default) |
  | `claude-haiku-5-5` | `us.anthropic.claude-haiku-5-5` | `haiku` (also background tasks) |

No other gateway change is needed for Claude Code. An `AgentgatewayModel` already accepts the Anthropic
Messages API at `/v1/messages` and translates it for Bedrock.

> A cluster made without `kind-config.yaml` cannot get the port mapping afterwards. Delete it first:
> `kind delete cluster --name agentgateway-codex`.

Test without Claude Code:

```sh
curl -s localhost:8080/v1/messages -H content-type:application/json -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-sonnet-5-5","max_tokens":50,"messages":[{"role":"user","content":"Say hi"}]}' \
  | jq -r '.content[0].text'
```

## Step 2 — Create the profile

```sh
scripts/claude-code-profile.sh
echo "alias claude-agw='\$HOME/.claude-agentgateway/bin/claude-agw'" >> ~/.zshrc && source ~/.zshrc
```

The script writes `~/.claude-agentgateway/settings.json`, installs the `claude-agw` launcher, and adds
the `solo-search` MCP server to the profile. The settings file:

```json
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
```

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

The calls also show on the UI Logs and Analytics pages (main README, Step 13).

## Step 5 — Optional: Entra ID sign-in

With this on, the gateway answers 401 without a valid Entra token and 403 unless you are in the allowed
group, for the models and the MCP server. `claude-agw` opens the Microsoft sign-in page when you have
no usable sign-in, and the Logs page shows who made each call.

**1. Create the Entra group and app registration** (once per tenant; needs `az login`). The script
reuses them if they exist and prints three `export` lines. Run those. The
[Entra guide](../entra-id/README.md), Steps 1–3, explains each setting.

```sh
scripts/entra-setup.sh
export TENANT_ID=... APP_ID=... GROUP_ID=...
```

**2. Turn it on at the gateway.** With the three variables set, `deploy.sh` applies
[`k8s/06-entra-auth.yaml`](../k8s/06-entra-auth.yaml) and puts the sign-in name in the request logs:

```sh
scripts/deploy.sh
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8080/v1/messages    # 401
```

**3. Switch the profile to Entra sign-in:**

```sh
scripts/claude-code-profile.sh        # with TENANT_ID and APP_ID still set
```

This changes three things in the profile:

- `settings.json` gets `"apiKeyHelper": "~/.claude-agentgateway/entra-token.py"` and loses
  `ANTHROPIC_AUTH_TOKEN`. Claude Code runs the helper and sends its output as the bearer token.
- The MCP server gets `"headersHelper": "~/.claude-agentgateway/entra-token.py headers"`, so the same
  sign-in covers `/mcp`. There is no second sign-in and no extra redirect URI to register.
- `entra.json` holds the tenant and app IDs. Neither is a secret.

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

To turn sign-in off again: delete the two policies (Entra guide, "Turn it off") and rerun
`scripts/claude-code-profile.sh` without `TENANT_ID` and `APP_ID`.

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
- **Codex on the same gateway.** Point it at `http://localhost:8080/v1` (main README, Step 10). With
  Entra on, follow the [Entra guide](../entra-id/README.md) from Step 6; the MCP callback ID in its
  Step 8 depends on the gateway address, so it changes once when you move to port 8080.

## Cleanup

```sh
rm -rf ~/.claude-agentgateway                       # profile, sign-in, history
kind delete cluster --name agentgateway-codex       # also deletes the Postgres data
# and remove the claude-agw alias from ~/.zshrc
```

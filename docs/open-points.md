# Open points and decisions

Tracks the questions the plan left open, the decisions taken while building the
repository, and every `TEMPLATE` / `VERIFY` marker that has to be confirmed on the
cluster.

## Open points from the plan

| # | Question | Status | Notes |
|---|---|---|---|
| 1 | OpenShift version supported by OpenShift AI 3.5 and AAP 2.6 | 🟡 Partially answered | Cluster runs **OCP 4.22.22**; `rhods-operator` 3.5.3 and AAP `stable-2.6` are both offered by the cluster catalog and run. Still confirm in the KB *Supported Configurations for 3.x* and in the AAP 2.6 lifecycle page |
| 2 | Exact operator package names | ✅ Answered | `rhods-operator` (stable-3.5), `ansible-automation-platform-operator` (stable-2.6), `rhcl-operator` (stable), `openshift-cert-manager-operator` (installed), `openshift-external-secrets-operator` (stable-v1), `mcp-gateway` (preview, phase 2) |
| 3 | How OpenClaw receives alerts via webhook | ✅ Answered | `hooks` mapping at `/hooks/alertmanager` (Bearer token) from an `AlertmanagerConfig`; reaches the agent ~55 s after the alert fires. Each alert is an isolated one-shot run (test-log F-15) |
| 4 | Which Kubernetes and Prometheus MCP servers to use | ✅ Chosen and running | Kubernetes: `containers/kubernetes-mcp-server` (upstream of Red Hat `openshift-mcp-server`), read-only TOML config (F-08). Prometheus: `pab1it0/prometheus-mcp-server` v1.6.2. Not evaluated: `rhobs/obs-mcp` |
| 5 | MaaS ↔ NeMo Guardrails order with an external model | ✅ Answered | Topology A (MaaS → Guardrails) breaks the token quota (F-05). Topology B (Guardrails → MaaS) works for non-streaming clients only; OpenClaw always streams, so **Guardrails runs standalone** (F-09) |
| 6 | Does EvalHub red teaming work against an external model without GPU? | ✅ Answered | Yes. Garak `quick` ran as a CPU job against the corporate MaaS (test-log F-07) |

## New open points found while structuring

| # | Question | Status | Notes |
|---|---|---|---|
| 7 | Does NeMo Guardrails pass OpenAI `tools` / `tool_calls` through? | ✅ Only with `passthrough: true`, non-streaming (15/15) | F-06, F-09 |
| 8 | Do NeMo input rails see tool outputs (logs) or only the user message? | ✅ Answered: **only the user message** | Case 4 (Run 4): the injected log text is blocked as a user message and passes as a tool result. Guardrails in the agent path would not catch log-borne injections without output/tool rails |
| 9 | OpenClaw MCP configuration key | ✅ Answered | `mcp.servers` (streamable-http, `headers`, `toolFilter.include`) accepted by OpenClaw 2026.9.8 (`config validate`, `mcp doctor`) |
| 10 | OpenClaw OTel export to MLflow | ✅ Answered | Starter kit OTel sidecar (projected SA token + `mlflow-operator-mlflow-integration`, workspace header); traces arriving |
| 11 | Ansible MCP server: CR fields, Service name, pod labels | ✅ Answered | `AnsibleMCPServer aap-mcp`: Service `aap-mcp:8086`, toolset path `/job_management/mcp`, pod label `app.kubernetes.io/component=ansible-mcp-server` |
| 12 | Alert template syntax in OpenClaw hook mappings | ✅ Answered | `{{commonLabels.alertname}}` style works (session title `Alert DemoAppCrashLooping`) |
| 13 | User-workload Thanos Ruler access to kube-state-metrics | ✅ Answered | `DemoAppCrashLooping` fired from the user-workload ruler |
| 14 | MaaS gateway internal address | ✅ Answered | `maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local`, used by the agent and Guardrails (`RHOAI_MAAS_INTERNAL_URL`) |
| 15 | Text-encoded tool calls from `llama-scout-17b` with `tool_choice=auto` | ✅ Superseded | Model changed to `qwen3-14b` (0/15 text-encoded calls without hint). Mitigation for llama in F-01 |
| 16 | Corporate MaaS streaming tool-call parser (`qwen3-14b`) | 🟡 **Mitigated** | The end of streamed arguments is lost when the last argument is not a string (F-14, F-18). Mitigated by string-only tools (launch layer) and detected by `model-validation/streaming_args_test.py`. Root fix: MaaS owners. `gpt-oss-120b` passes the streaming gate |

## Decisions

| Date | Decision | Reason |
|---|---|---|
| 2026-11-19 | **Launch layer `aap-actions`** (intent-level MCP tools, string-only arguments, no credential) for launches and approval status; Ansible MCP kept for read tools | F-18 and F-20; narrower action surface without new authority (D-5) |
| 2026-11-19 | Streaming argument gate added to `make model-validate` | The non-streaming gate passed a model that broke in OpenClaw (F-18) |
| 2026-11-19 | Slack channel **tested, then disabled**; the repo keeps it optional (`make slack-enable`) | Proved the handoff (alert → channel → thread session). A corporate workspace needs admin approval; case 2 is blocked by F-18 regardless of the channel |
| 2026-11-19 | Slack egress through an `EgressFirewall` with **explicit host names** | Wildcards need `DNSNameResolver`; an unsupported rule disables the whole firewall (F-16) |
| 2026-11-19 | Alert runs only propose; no claims without a tool result (`AGENTS.md`) | The model claimed a launch that never happened (F-17) |
| 2026-11-19 | Model changed to **`qwen3-14b`** (GO, 15/15 without hint) | Handles the untrusted-content wrapper on webhook alerts (D-3, F-13) |
| 2026-11-19 | MCP tools allowlisted (`toolFilter.include`) for Kubernetes and Prometheus | Least privilege + workaround for empty streamed arguments (F-14) |
| 2026-11-19 | Agent → **MaaS directly**; Guardrails standalone (separate subscription) | OpenClaw always streams; NeMo accepts tools only without streaming (F-09). Replaces the earlier "topology B" decision |
| 2026-11-19 | Guardrails Route (created by the TrustyAI operator) restricted with an IP allowlist | Guardrails has no authentication and calls the model with a MaaS key |
| 2026-11-19 | MLflow with SQLite + PVC (no S3) | Supported by the operator; traces live in the backend store. ODF/NooBaa remains available if needed |
| 2026-11-19 | Authorino listener TLS disabled; Authorino trusts the service CA instead | RHCL 1.4.3 calls Authorino in plaintext; the real requirement is Authorino → maas-api over HTTPS (F-03) |
| 2026-11-19 | Model consumers are ServiceAccounts in `aiops-models` (one MaaSSubscription each) | Independent quotas for case 5; keys minted with short-lived SA tokens (`scripts/maas-mint-keys.sh`) |
| 2026-11-18 | Model: `llama-scout-17b` (GO, 100% with tool hint), replaced on 2026-11-19 | Only model available to the key at the time; passed the gate with the mitigation in F-01 |
| 2026-11-18 | Do not manage cert-manager in this repo | Already installed (1.20.1, `stable-v1`) |
| 2026-11-18 | Identity layer: **ESO with a Kubernetes provider** reading from `poc-vault` | Shows the pattern (agent never holds the source secret) without an external vault; the provider can be swapped |
| 2026-11-18 | Agent pod: `automountServiceAccountToken: false` + SA without bindings + no egress to the API server | Success criterion 1 enforced by three independent controls |
| 2026-11-18 | Agent can launch only **workflows with an approval node** (plus read-only `collect-diagnostics`) | Write actions always need a human; approval is a separate AAP user |
| 2026-11-18 | Added a 5th template `set-memory-limit`, **EDA-only** | Case 3 needs a "tuning" action that is not part of the agent catalog |
| 2026-11-18 | Prometheus MCP uses Thanos Querier port 9091 + `cluster-monitoring-view` | The tenancy port (9092) needs a `namespace` parameter the MCP server does not send. Still read-only metrics |
| 2026-11-18 | Rulebooks under `extensions/eda/rulebooks/` | EDA project import only discovers rulebooks there or in `rulebooks/` at the repo root |
| 2026-11-18 | Community `openclaw-operator` (catalog) not used | Not a Red Hat product; the RHOAI starter kit is used (D-2) |
| 2026-11-18 | AAP channel `stable-2.6` (not the default `stable-2.7`) | Follows the plan; 2.7 is available if the 2.6 MCP server has issues |

## Owner decisions

| # | Decision | Status |
|---|---|---|
| D-1 | How to attach the AAP subscription | ✅ Attached by the owner through the UI (60-day trial) |
| D-2 | OpenClaw deployment path | ✅ RHOAI agentic starter kit (`red-hat-data-services/agentic-starter-kits/agents/openclaw`), link provided by the owner |
| D-3 | Webhook alerts produce an empty agent reply (test-log F-12) | ✅ **Option (c)**: the owner added `qwen3-14b` to the corporate MaaS; the untrusted-content wrapper stays on (F-13). Options considered: (a) `allowUnsafeExternalContent: true` on the Alertmanager mapping only (blocked by the assistant's safety classifier; needs an explicit owner decision); (b) keep the wrapper and route alerts through a trusted path; (c) another model |
| D-4 | Chat channel for the human handoff (test-log F-15) | ✅ **Tested in a separate Slack workspace, then disabled.** A corporate workspace needs admin approval to install the app (not requested). Repo ready: [slack-app-manifest.json](../manifests/phase3-agent/slack/slack-app-manifest.json), `make slack-enable`. Without it, case 2 starts from a new Control UI chat |
| D-5 | How to unblock case 2 (F-18) | ✅ **Launch layer** (owner's choice, as a pattern and not only a workaround). Reporting the parser bug to the corporate MaaS owners remains recommended (reproduction in F-18 and the streaming gate) |

## TEMPLATE / VERIFY inventory

| File | What to verify |
|---|---|
| ~~MaaS, NemoGuardrails, MLflow, EvalHub manifests~~ | ✅ Validated against the served schemas on 2026-11-19 |
| ~~`manifests/phase3-agent/openclaw/openclaw.json5`~~ | ✅ `config validate` with OpenClaw 2026.9.8 |
| ~~`manifests/phase3-agent/base/networkpolicies.yaml`~~ | ✅ `make isolation` 10/10 |
| ~~`manifests/phase4-tools/ansible-mcp/ansiblemcpserver.yaml`~~ | ✅ Running (`mcp doctor ansible`) |
| ~~`manifests/phase4-tools/mcp-prometheus/deployment.yaml`~~ | ✅ Running (6 tools, none mutating) |
| ~~`aap/config-as-code/configure-aap.yml`~~ | ✅ Applied in-cluster with the AAP 2.6 EE |
| `manifests/phase4-tools/aap-actions/server.py` | POC code: keep tool arguments string-only (F-18); re-check if AAP API fields change |
| `manifests/phase3-agent/slack/slack-app-manifest.json` | The reduced scope list worked for posting and thread replies; re-check if the plugin version changes |

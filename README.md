# AIOps with OpenClaw on the Red Hat platform

A proof of concept of an **AIOps agent built on [OpenClaw](https://openclaw.ai)**. The agent
diagnoses incidents in an OpenShift cluster and proposes fixes; the Red Hat platform decides
what it is allowed to do.

> **Thesis.** Choosing the model decides how the agent *thinks*. It does not decide what
> the agent can *do*. This POC shows the platform layers that control what the agent does:
> isolation, identity, tools, content, traceability, action and scale.

---

## Contents

1. [How it works](#how-it-works)
2. [The seven control layers](#the-seven-control-layers)
3. [Architecture](#architecture)
4. [Test cases and results](#test-cases-and-results)
5. [Running the POC](#running-the-poc)
6. [Repository layout](#repository-layout)
7. [Risks and lessons](#risks-and-lessons)
8. [Documentation](#documentation) · [References](#references)

---

## How it works

An alert reaches the agent, the agent investigates with read-only tools and proposes a fix,
and a person decides. Every change goes through Ansible Automation Platform and waits for a
human approval.

```mermaid
sequenceDiagram
    autonumber
    participant AM as Alertmanager
    participant OC as OpenClaw
    participant M as MaaS → model
    participant MCP as Read-only MCP
    participant A as Launch layer / AAP
    actor H as Human (approver)
    participant ML as MLflow

    AM->>OC: webhook (DemoAppCrashLooping)
    OC->>M: reason about the alert
    OC->>MCP: pods, events, logs, metrics
    OC-->>H: root cause + proposed action (chat)
    H->>OC: "go ahead with the rollback"
    OC->>A: launch_remediation(wf-rollback-deployment, checkout, demo-apps)
    A-->>H: approval request
    H->>A: approve
    A->>A: run rollback-deployment (SA aap-automation)
    OC->>MCP: verify recovery
    OC-->>H: application recovered
    OC-)ML: traces of every step
```

Known, repetitive incidents skip the agent: Event-Driven Ansible fixes them with a fixed rule,
at zero inference cost.

## The seven control layers

| # | Challenge | Component in the POC | Support status | In the POC? |
|---|---|---|---|---|
| 01 | Isolation | Restricted SCC + Pod Security `restricted` + **default-deny NetworkPolicy** in the agent namespace; agent tools deny-list (no shell) | GA | Yes |
| 02 | Identity | Credentials in a restricted "vault" namespace, synced by **External Secrets Operator**; agent has no Kubernetes token | GA | Yes |
| 03 | Tools | **Read-only MCP servers** (Kubernetes, Prometheus) with read-only RBAC on `demo-apps` | GA | Yes (phase 1) |
| 03 | Tools | MCP Gateway (identity-based authorization) | Technology Preview | Phase 2 |
| 04 | Content | **NeMo Guardrails** (credentials, personal data, prompt injection) | GA (3.4) | Yes, **standalone**: cannot sit in the agent path (OpenClaw streams, F-09) |
| 05 | Traceability | **MLflow tracing** (OpenTelemetry from OpenClaw) | GA (3.4) | Yes |
| 05 | Traceability | **EvalHub** + automated red teaming (Garak) | GA (3.5) | Yes (model evaluation) |
| 06 | Action | **AAP** job template catalog + **approval workflows** | GA | Yes |
| 06 | Action | **Ansible MCP server** | GA (AAP 2.6, Jun/2026) | Yes: read tools (catalog, job status, output) |
| 06 | Action | **Launch layer** `aap-actions`: intent-level MCP tools in front of AAP | POC code | Yes: launches and approval status ([why](docs/architecture.md#launch-layer-aap-actions)) |
| 06 | Action | **Event-Driven Ansible** for known events (no AI) | GA | Yes |
| 07 | Scale | **Models-as-a-Service** with a per-agent quota | GA (3.4) | Yes |
| 07 | Scale | MaaS pointing to an **external model** | Technology Preview (3.5) | Yes: this is what provides a quota without GPUs |
| — | Deployment | OpenClaw starter kit (OpenShift AI 3.5) | Developer Preview | **Used** (`agentic-starter-kits/agents/openclaw`) |
| — | Isolation | OpenShell | Developer Preview | Out of scope |

## Architecture

```mermaid
flowchart LR
    U["User<br/>OpenClaw Control UI<br/>(Slack: optional)"]

    subgraph OCP["OpenShift cluster"]
        subgraph AG["ns: openclaw · default-deny · no SA token"]
            OC["OpenClaw agent"]
        end

        VAULT[("ns: poc-vault<br/>credentials")]
        ESO["External Secrets<br/>Operator"]

        subgraph RHOAI["OpenShift AI 3.5"]
            MAAS["Models-as-a-Service<br/>per-agent quota"]
            GR["NeMo Guardrails"]
            MLF["MLflow<br/>tracing"]
            EVH["EvalHub<br/>+ Garak"]
        end

        subgraph TOOLS["ns: aiops-tools"]
            MK["Kubernetes MCP<br/>view on demo-apps"]
            MP["Prometheus MCP<br/>metrics only"]
            FAC["aap-actions<br/>launch layer"]
        end

        subgraph AAPNS["ns: aap · Ansible Automation Platform 2.6"]
            AMCP["Ansible MCP server<br/>(read tools)"]
            CTRL["Automation Controller<br/>catalog + approval"]
            EDA["Event-Driven Ansible"]
        end

        MON["User workload monitoring<br/>Prometheus · Alertmanager"]
        APP["ns: demo-apps<br/>test applications"]
    end

    EXT["Corporate MaaS<br/>(model)"]

    U <--> OC
    VAULT --> ESO -- "only the agent's keys" --> OC
    MON -- "alert (webhook)" --> OC
    MON -- "known events" --> EDA
    OC -- "agent MaaS key" --> MAAS --> EXT
    GR -.->|"standalone consumer"| MAAS
    OC -.->|"traces (OTLP)"| MLF
    OC --> MK
    OC --> MP
    OC -- "read: catalog, job output" --> AMCP --> CTRL
    OC -- "launch_remediation<br/>(agent's AAP token)" --> FAC --> CTRL
    CTRL -- "SA aap-automation<br/>(write only in demo-apps)" --> APP
    EDA --> CTRL
    EVH -.->|"evaluates"| EXT
    MK -. read .-> APP
```

Key design decisions:

- **The agent holds no Kubernetes credential.** Its ServiceAccount has no RoleBindings and
  its token is not mounted. Reads go through MCP servers that run under their own
  read-only identities. Writes go through AAP, whose ServiceAccount is the only identity
  that can write to `demo-apps`.
- **Every write action requires human approval.** The agent can only launch *workflows*.
  Each workflow starts with an approval node, and only the `poc-approver` user can approve it.
- **The agent launches actions through intent-level tools.** `launch_remediation(workflow,
  deployment, namespace)` and `remediation_status(job)` in a small launch layer replace the
  generic AAP API calls: flat string arguments the model gets right, a narrower surface, and
  plain answers ("denied by poc-approver"). The layer holds no credential: it forwards the
  agent's AAP token, so AAP RBAC, surveys and approvals stay the control.
- **Known events skip the model.** Alertmanager sends them straight to EDA, which gives a
  deterministic fix at zero inference cost.
- **The agent reaches the model only through MaaS** (per-agent token quota). NeMo Guardrails
  could not be placed in the agent path in this release (OpenClaw always streams; NeMo accepts
  tools only without streaming), so it runs standalone, as the plan's risk table foresees. See
  [docs/architecture.md](docs/architecture.md#model-path-maas-and-guardrails-order).
- **Alerts run as isolated, one-shot agent runs.** The diagnosis is read in the Control UI, or
  in a Slack channel where operators answer in the thread (optional, prepared and tested;
  [architecture](docs/architecture.md#alert-sessions-and-the-human-handoff)).
- **OpenClaw is deployed with the RHOAI agentic starter kit** (kustomize remote base pinned to
  a commit) plus a POC overlay: ESO-managed Secret, POC config, agent rules, MLflow tracing
  sidecar (the only container with a ServiceAccount token).

Details: [docs/architecture.md](docs/architecture.md).

## Test cases and results

All five cases were executed on 2026-11-19. Details, evidence and findings:
[test log](docs/test-log.md#current-status).

| Case | What it shows | Result |
|---|---|---|
| 1. Read-only diagnosis | The agent finds the root cause and only proposes a fix | ✅ |
| 2. Action with approval | Nothing changes until a person approves in AAP; a denial changes nothing | ✅ |
| 3. Known event without AI | EDA fixes a known incident with no model call | ✅ |
| 4. Prompt injection | Malicious log text causes no damage and no leak | ✅ (agent ignored the injection without flagging it) |
| 5. Per-agent quota | MaaS blocks the agent's key and not other consumers | ✅ |

| # | Success criterion | Result |
|---|---|---|
| 1 | **0** credentials with write permission reachable by the agent process | ✅ `make verify` 17/17 |
| 2 | **0** actions executed outside the AAP catalog | ✅ every change came from an AAP job |
| 3 | **100%** of agent decisions traceable in MLflow | ✅ every agent run of the tests has a trace with its tool calls |
| 4 | **0** privilege escalation from prompt injection | ✅ |
| 5 | Quota enforced by MaaS | ✅ HTTP 429 for the agent, 200 for the other consumer |
| 6 | Time from alert to diagnosis recorded (MTTR reference) | ✅ ≈ 1.5 min |

## Running the POC

**Scope.** Internal POC in a lab cluster, with fictitious applications and logs only.
Reference versions (November 2026): OpenShift 4.22, OpenShift AI 3.5, AAP 2.6. **No GPU**:
inference comes from a corporate MaaS (OpenAI-compatible API), so vLLM / llm-d are out of
scope.

**Prerequisites:** `oc` logged in as cluster-admin, `python3`, `curl`, and access to the
corporate MaaS. AAP is configured from inside the cluster (no local Ansible).

```bash
cp .env.example .env              # fill in MaaS URL/key, tokens, passwords
make preflight                    # read-only cluster checks
make egress-check                 # MaaS reachable from a pod?        (gate)
make model-list model-validate    # model picks the right tools?       (gate)

make phase0                       # user workload monitoring
make operators platform           # RHCL, RHOAI 3.5, AAP 2.6, ESO
make explain-crds                 # adjust TEMPLATE files to the served schemas
make governance                   # MaaS, Guardrails, MLflow, EvalHub
make demo-apps tools              # test apps, alerts, MCP servers, launch layer
make maas-prereqs maas-keys       # MaaS gateway/DB/Authorino CA, one key per consumer
make aap-config ansible-mcp       # catalog, approval workflows, EDA, Ansible MCP (in-cluster)
make agent                        # OpenClaw via the RHOAI starter kit + POC overlay
make verify                       # privilege checks: agent cannot write anything
```

Full runbook: [docs/installation.md](docs/installation.md). Test cases:
[docs/test-plan.md](docs/test-plan.md). What to look at during the tests:
[docs/access.md](docs/access.md).

<details>
<summary>Target environment used (discovered on 2026-11-18)</summary>

| Item | Value |
|---|---|
| OpenShift | 4.22.22 |
| Nodes | 3 control plane (schedulable) + 3 workers, 16 vCPU / 64 GiB each: 96 vCPU / 384 GiB in total |
| Storage | ODF (external Ceph): default `ocs-external-storagecluster-ceph-rbd`; S3 via NooBaa (`openshift-storage.noobaa.io`) |
| Already installed | cert-manager Operator 1.20.1, ODF 4.21, RHBK 26.4 |
| Catalog channels used | `rhods-operator` stable-3.5 (3.5.3), `ansible-automation-platform-operator` stable-2.6, `rhcl-operator` stable, `openshift-external-secrets-operator` stable-v1 |

</details>

## Repository layout

```text
.
├── Makefile                      # one target per installation step (make help)
├── .env.example                  # all environment-specific values (copy to .env)
├── docs/
│   ├── architecture.md           # components, network, identities, flows
│   ├── installation.md           # step-by-step runbook (phases 0-4)
│   ├── access.md                 # observation tools: what a human checks, per test case
│   ├── test-plan.md              # test cases, expected results, evidence to collect
│   ├── test-log.md               # test notebook: results of the executed tests
│   └── open-points.md            # open questions, decisions, verification log
├── model-validation/             # model gate: tool calling + streamed argument shapes (go / no-go)
├── manifests/
│   ├── phase0-environment/       # user workload monitoring + Alertmanager
│   ├── phase1-operators/         # Subscriptions: RHCL, RHOAI 3.5, AAP 2.6, ESO
│   ├── phase1-platform/          # Kuadrant, DataScienceCluster, AAP instance, ESO operand
│   ├── phase2-governance/        # MaaS, NeMo Guardrails, MLflow, EvalHub
│   ├── phase3-agent/             # namespace, NetworkPolicies, ExternalSecret, starter-kit overlay, optional Slack channel
│   ├── phase4-tools/             # MCP servers (read-only), launch layer (aap-actions), AAP SA, Ansible MCP server
│   └── demo-apps/                # test apps (cases 1-4), PrometheusRules, Alertmanager routing
├── aap/
│   ├── playbooks/                # job template catalog (kubernetes.core)
│   └── config-as-code/           # AAP objects: catalog, surveys, approval workflows, EDA
├── extensions/eda/rulebooks/     # EDA rulebook (path required by EDA project import)
├── collections/requirements.yml  # collections synced by the AAP project
└── scripts/                      # preflight, secrets, privilege checks, test triggers, evidence
```

> Files marked **`TEMPLATE` / `VERIFY`** target Technology or Developer Preview APIs whose
> schema can change between releases. Run `make explain-crds` after the operators are
> installed and adjust them; [open-points.md](docs/open-points.md) tracks each one.

## Risks and lessons

| Risk | What happened / fallback |
|---|---|
| Cluster has no route to the corporate MaaS | Fix networking before any installation; the POC cannot proceed without it |
| MaaS model weak at tool calling | **Happened**: `llama-scout-17b` → `qwen3-14b` (F-01, F-12, F-13) |
| Corporate MaaS streaming tool-call parser mangles arguments | **Happened** (F-14, F-18): mitigated with string-only arguments in the launch layer; detected up front by `model-validation/streaming_args_test.py`. Root fix belongs to the MaaS owners |
| OpenClaw starter kit (Developer Preview) does not work | Did not happen: the starter kit deployed successfully with the POC overlay |
| MaaS with an external model (Technology Preview) does not work | Did not happen. Fallback: OpenClaw calls the corporate MaaS directly; quota shown only with the corporate MaaS key limits |
| Guardrails does not support the external model / tool calls | **Happened** (OpenClaw streams; F-09): Guardrails runs standalone in phase 1 |
| Corporate MaaS quota exhausted | Long heartbeat (30 min); concentrate tests in short windows |
| Not enough cluster resources | Lean DataScienceCluster and AAP without Automation Hub (already the default here) |

## Documentation

| Document | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Components, namespaces, network policies, identities, detailed flows |
| [docs/installation.md](docs/installation.md) | Runbook, phase by phase, with verification commands |
| [docs/access.md](docs/access.md) | Observation tools (human checkpoints): what each one is for, how to open it, what to look at per test case |
| [docs/test-plan.md](docs/test-plan.md) | The five test cases: setup, steps, expected results, evidence |
| [docs/test-log.md](docs/test-log.md) | Test notebook: what was executed, when, and the results |
| [docs/open-points.md](docs/open-points.md) | Open questions, decisions taken, items to verify |

## References

- [OpenShift AI 3.5: Release notes, new features (EvalHub, red teaming)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/release_notes/new-features-and-enhancements_relnotes)
- [OpenShift AI 3.5: Technology Preview features](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/release_notes/technology-preview-features_relnotes)
- [OpenShift AI 3.5: Developer Preview features (OpenClaw starter kit, OpenShell)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/release_notes/developer-preview-features_relnotes)
- [OpenShift AI 3.4: Govern LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas)
- [OpenShift AI 3.5: Enabling AI safety with Guardrails](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/enabling_ai_safety_with_guardrails/enabling-ai-safety-with-guardrails_safety)
- [OpenShift AI 3.4: Working with MLflow](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/working_with_mlflow)
- [OpenShift AI 3.5: Evaluate LLMs with EvalHub](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/evaluating_ai_systems/evaluating-llms-with-evalhub_evaluate)
- [AAP 2.6: Operator growth topology](https://docs.redhat.com/de/documentation/red_hat_ansible_automation_platform/2.6/plan-ref_ocp_a_env_a)
- [AAP 2.6: What's new, June 3 2026 update (Ansible MCP server GA)](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.6/whats_new-2.6_2026_06_03)
- [AAP 2.7: Deploy the Ansible MCP server](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/extend-assembly_deploying_ansible_mcp_server)
- [Red Hat Blog: Bring Your Own Agent, OpenClaw edition](https://www.redhat.com/en/blog/operationalizing-bring-your-own-agent-red-hat-ai-openclaw-edition)
- [Red Hat Emerging Technologies: OpenClaw on OpenShift (claw-operator)](https://next.redhat.com/?p=4432)

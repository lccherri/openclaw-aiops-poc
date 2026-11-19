# AIOps with OpenClaw on Red Hat platform - POC automation.
# Each target maps to a step of docs/installation.md. Run `make help`.
SHELL := /bin/bash
.DEFAULT_GOAL := help
M := manifests

##@ Phase 0 - Environment
preflight: ## Read-only cluster checks (versions, nodes, storage, catalog)
	@scripts/00-preflight.sh

egress-check: ## Verify a pod can reach the corporate MaaS (/v1/models)
	@scripts/01-maas-egress-check.sh

model-list: ## List models available in the corporate MaaS
	@set -a; source .env; set +a; python3 model-validation/tool_calling_test.py --list-models

model-validate: ## Model gate for MAAS_MODEL: tool calling + streamed argument shapes (go / no-go)
	@mkdir -p evidence; set -a; source .env; set +a; \
	python3 model-validation/tool_calling_test.py --runs 3 --json-out evidence/model-validation.json
	@set -a; source .env; set +a; python3 model-validation/streaming_args_test.py --runs 3

phase0: ## Enable user workload monitoring + dedicated Alertmanager
	oc apply -k $(M)/phase0-environment
	@until oc get ns openshift-user-workload-monitoring >/dev/null 2>&1; do sleep 5; done
	oc apply -f $(M)/phase0-environment/user-workload-monitoring-config.yaml

##@ Phase 1 - Platform
operators: ## Subscribe RHCL, RHOAI 3.5, AAP 2.6, External Secrets (cert-manager already present)
	oc apply -k $(M)/phase1-operators
	@source scripts/lib.sh; \
	wait_for_csv kuadrant-system rhcl-operator; \
	wait_for_csv redhat-ods-operator rhods-operator; \
	wait_for_csv aap aap-operator; \
	wait_for_csv external-secrets-operator external-secrets-operator

platform: ## Create Kuadrant, DataScienceCluster, AAP instance and ESO operand
	oc apply -f $(M)/phase1-platform/external-secrets/externalsecretsconfig.yaml
	oc apply -f $(M)/phase1-platform/rhcl/kuadrant.yaml
	oc apply -f $(M)/phase1-platform/rhoai/datasciencecluster.yaml
	oc apply -f $(M)/phase1-platform/aap/ansibleautomationplatform.yaml
	@source scripts/lib.sh; \
	wait_for_jsonpath datasciencecluster/default-dsc "" '{.status.phase}' Ready 1800

maas-prereqs: ## MaaS prerequisites: Gateway, PostgreSQL, Authorino CA trust (idempotent)
	@scripts/maas-prereqs.sh

explain-crds: ## Dump schemas of preview CRDs (adjust templates before Phase 2)
	@scripts/explain-crds.sh

##@ Phase 2 - Model governance
render: ## Render git-ignored config (agent.env, guardrails config) from .env
	@scripts/render-config.sh

governance: render ## MaaS model + subscriptions, Guardrails, MLflow, EvalHub
	oc apply -f $(M)/phase2-governance/maas/namespace.yaml -f $(M)/phase2-governance/guardrails/namespace.yaml
	@scripts/create-secrets.sh
	oc apply -k $(M)/phase2-governance

maas-keys: ## Mint one MaaS key per consumer ServiceAccount and store them in .env
	@scripts/maas-mint-keys.sh
	@scripts/create-secrets.sh

evalhub: ## Run the Garak red-team evaluation through EvalHub (BENCHMARK=quick by default)
	@scripts/evalhub-run.sh

##@ Phase 3 - Agent
secrets: ## Create/refresh all Secrets from .env (idempotent)
	@scripts/create-secrets.sh

agent-base: ## Namespace openclaw, default-deny NetworkPolicies, ExternalSecret
	@scripts/create-secrets.sh
	oc apply -k $(M)/phase3-agent/base

agent: render agent-base ## Deploy OpenClaw with the RHOAI starter kit + POC overlay
	oc apply -k $(M)/phase3-agent/starter-kit
	oc -n openclaw rollout status deploy/openclaw --timeout=480s
	@echo "Control UI: https://$$(oc -n openclaw get route openclaw -o jsonpath='{.spec.host}')"

slack-enable: ## OPTIONAL: Slack channel for alerts + human follow-up (needs SLACK_* in .env)
	@scripts/slack.sh enable

slack-disable: ## Remove the Slack channel (back to isolated alert sessions, no external egress)
	@scripts/slack.sh disable

##@ Phase 4 - Tools and action
demo-apps: ## Demo applications, PrometheusRules and Alertmanager routing
	oc apply -k $(M)/demo-apps
	@scripts/create-secrets.sh

tools: ## Read-only MCP servers, launch layer (aap-actions), AAP ServiceAccount scoped to demo-apps
	oc apply -k $(M)/phase4-tools

aap-config: ## Configure AAP as code (catalog, workflows with approval, EDA)
	@scripts/aap-configure.sh

ansible-mcp: ## Deploy the Ansible MCP server (validate the template first)
	oc apply -f $(M)/phase4-tools/ansible-mcp/ansiblemcpserver.yaml

##@ Phase 5 - Tests
verify: ## Privilege checks (success criteria #1 and #4)
	@scripts/verify-agent-privileges.sh

isolation: ## Network isolation probe from the agent namespace (MCP tools, launch layer, blocked paths)
	@set -a; source .env; set +a; \
	POD_LABELS=app.kubernetes.io/name=openclaw scripts/incluster-python.sh openclaw scripts/isolation-probe.py \
	  "$$(python3 -c 'import sys,urllib.parse;print(urllib.parse.urlparse(sys.argv[1]).hostname)' "$$MAAS_INTERNAL_URL")"

case%-trigger: ## Trigger a test case, e.g. make case1-trigger
	@scripts/cases/run-case.sh $* trigger

case%-reset: ## Reset a test case, e.g. make case1-reset
	@scripts/cases/run-case.sh $* reset

status: ## Pods and recent events in demo-apps
	@scripts/cases/run-case.sh 0 status

evidence: ## Collect evidence (workloads, events, AAP jobs + approvals, launch audit) into evidence/<timestamp>/
	@scripts/collect-evidence.sh

##@ Housekeeping
lint: ## Validate YAML and kustomize builds offline
	@python3 -c "import yaml,glob,sys; fs=[f for f in glob.glob('**/*.y*ml',recursive=True) if not f.startswith('context/')]; [list(yaml.safe_load_all(open(f))) for f in fs]; print(f'YAML OK ({len(fs)} files)')"
	@for k in $(M)/phase0-environment $(M)/phase1-operators $(M)/phase3-agent/base $(M)/phase4-tools $(M)/demo-apps; do \
	  oc kustomize $$k >/dev/null && echo "kustomize OK: $$k"; done

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n"} /^[a-zA-Z0-9_%-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: preflight egress-check model-list model-validate phase0 operators platform maas-prereqs explain-crds render governance maas-keys evalhub isolation secrets agent-base agent slack-enable slack-disable demo-apps tools aap-config ansible-mcp verify status evidence lint help

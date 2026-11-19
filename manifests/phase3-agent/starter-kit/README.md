# Plan A - OpenClaw starter kit (OpenShift AI 3.5, Developer Preview)

The starter kit is the preferred deployment path. It is a Developer Preview, so its
exact artifacts may change; follow the RHOAI 3.5 release notes ("Developer Preview
features") and the Red Hat blog *Bring Your Own Agent - OpenClaw edition*.

## Checklist

1. Deploy the starter kit into the namespace `openclaw` created by `manifests/phase3-agent/base`
   (namespace, default-deny NetworkPolicies and ExternalSecret are shared with plan B).
2. Make sure the agent pod carries the label `app.kubernetes.io/name: openclaw`
   (the allow-rules of the NetworkPolicies select on it). Add it via the kit's values
   or a patch if needed.
3. Point the model provider to the MaaS endpoint (`MAAS_BASE_URL`) with the agent key
   (`MAAS_API_KEY` from Secret `openclaw-credentials`).
4. Reuse `../openclaw/openclaw.json5` for tools deny-list, MCP servers, hooks, heartbeat
   and OpenTelemetry settings, and `../openclaw/workspace/AGENTS.md` as agent rules.
5. Confirm `automountServiceAccountToken: false` (or an SA without RoleBindings).
6. Run `scripts/verify-agent-privileges.sh` - it must report zero write permissions.

## When to switch to plan B

Any blocker that cannot be solved in ~half a day (missing image, unsupported config,
operator errors). Record the reason in `docs/test-log.md` and run `make agent-plan-b`.

## Alternative found in the catalog

The cluster catalog also offers the community `openclaw-operator`
(`openclaw.rocks/v1alpha1`, channel `stable`). It is **not** a Red Hat product; an example
instance is kept in `../alt-community-operator/` for reference only.

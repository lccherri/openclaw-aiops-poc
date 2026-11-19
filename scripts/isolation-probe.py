"""
Isolation probe (control layers 01/03). Runs INSIDE the agent namespace, with the agent's
pod label, via:  scripts/incluster-python.sh openclaw scripts/isolation-probe.py
(POD_LABELS=app.kubernetes.io/name=openclaw is set by the Makefile target `isolation`).
Checks what the agent can and cannot reach, and lists the tools each MCP server exposes.
Standard library only.
"""
import json, socket, ssl, sys, urllib.request

# Upstream model host (corporate MaaS), passed by the Makefile from .env
UPSTREAM_HOST = sys.argv[1] if len(sys.argv) > 1 else ""

def mcp_tools(url):
    """Minimal MCP streamable-HTTP client: initialize + tools/list."""
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    def rpc(body, sid=None):
        hh = dict(h, **({"Mcp-Session-Id": sid} if sid else {}))
        r = urllib.request.urlopen(urllib.request.Request(url, json.dumps(body).encode(), hh), timeout=20)
        raw = r.read().decode(); sid = r.headers.get("Mcp-Session-Id") or sid
        for line in raw.splitlines():            # SSE or plain JSON
            if line.startswith("data:"): raw = line[5:]
        return (json.loads(raw) if raw.strip() else {}), sid
    _, sid = rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "isolation-probe", "version": "1"}}})
    try: rpc({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    except Exception: pass
    res, _ = rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, sid)
    return [t["name"] for t in res.get("result", {}).get("tools", [])]

def tcp(host, port, timeout=5):
    try:
        socket.create_connection((host, port), timeout=timeout).close(); return True
    except Exception: return False

results = []
def check(name, expected, ok, detail=""):
    status = "PASS" if ok == expected else "FAIL"
    results.append(status); print(f"[{status}] {name:55} reachable={ok} expected={expected} {detail}")

# --- must be reachable -------------------------------------------------------------
for name, url in [("kubernetes MCP", "http://kubernetes-mcp.aiops-tools.svc:8080/mcp"),
                  ("prometheus MCP", "http://prometheus-mcp.aiops-tools.svc:8080/mcp")]:
    try:
        tools = mcp_tools(url)
        verbs = ("delete", "create", "apply", "patch", "update", "scale", "exec", "run", "restart", "rollout")
        mutating = [t for t in tools if any(p in verbs for p in t.lower().split("_"))]
        check(name, True, True, f"tools={len(tools)} mutating={mutating or 'none'}")
        print("        tools:", ", ".join(sorted(tools)))
    except Exception as e:
        check(name, True, False, str(e)[:80])
# Launch layer: the only tools that can START a change, and only through AAP approval nodes
try:
    tools = mcp_tools("http://aap-actions.aiops-tools.svc:8080/mcp")
    check("aap-actions (launch layer -> AAP approvals)", True, True,
          f"tools={len(tools)} expected=['collect_diagnostics', 'launch_remediation']")
    print("        tools:", ", ".join(sorted(tools)))
    if sorted(tools) != ["collect_diagnostics", "launch_remediation"]:
        results.append("FAIL"); print("[FAIL] aap-actions exposes unexpected tools")
except Exception as e:
    check("aap-actions (launch layer -> AAP approvals)", True, False, str(e)[:80])
check("MaaS gateway (model path, agent key)", True,
      tcp("maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local", 443))
check("MLflow (traces)", True, tcp("mlflow.redhat-ods-applications.svc.cluster.local", 8443))

# --- must be blocked ------------------------------------------------------------------
check("kubernetes API (kubernetes.default.svc:443)", False, tcp("kubernetes.default.svc", 443))
check("NeMo Guardrails (not in the agent path)", False, tcp("aiops-guardrails.aiops-governance.svc", 80))
if UPSTREAM_HOST:
    check("corporate MaaS directly (bypass quota)", False, tcp(UPSTREAM_HOST, 443))
check("internet (1.1.1.1:443)", False, tcp("1.1.1.1", 443))
check("AAP gateway (not the MCP server)", False, tcp("aap.aap.svc", 80))

print(f"\nResult: {results.count('PASS')} passed, {results.count('FAIL')} failed")

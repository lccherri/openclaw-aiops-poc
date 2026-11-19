"""aap-actions: intent-level MCP tools in front of the AAP catalog (control layer 06).

Why: the generic Ansible MCP launch tools take a nested `requestBody` (JSON inside JSON). Over
a streaming model gateway those arguments can arrive truncated (docs/test-log.md F-18). These
tools take only flat, enumerated arguments and build the AAP request themselves.

What it is NOT: a new authority. The server holds no credential. It forwards the caller's
`Authorization` header (the AAP token of user `openclaw-agent`) to AAP, so AAP RBAC, surveys,
the playbook guard and the approval nodes decide exactly as before. The allowlists below are
defense in depth, not the control.

MCP streamable HTTP (JSON responses, stateless), Python standard library only.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AAP_URL = os.environ.get("AAP_URL", "http://aap.aap.svc.cluster.local").rstrip("/")
API = AAP_URL + "/api/controller/v2"
NAMESPACES = os.environ.get("ALLOWED_NAMESPACES", "demo-apps").split(",")
WORKFLOWS = ["wf-restart-deployment", "wf-rollback-deployment", "wf-scale-deployment"]
DIAG_TEMPLATE = "collect-diagnostics"
NAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")   # DNS-1123 label
PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]

TOOLS = [
    {
        "name": "launch_remediation",
        "description": (
            "Launch one remediation workflow from the AAP catalog. Every workflow starts with a "
            "HUMAN APPROVAL node in AAP: nothing changes until a person approves it. Use only when "
            "a person asked for the action. Returns the AAP workflow job id."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "workflow": {"type": "string", "enum": WORKFLOWS,
                             "description": "wf-rollback-deployment: undo the latest Deployment revision; "
                                            "wf-restart-deployment: rollout restart; "
                                            "wf-scale-deployment: set replicas (needs replicas)"},
                "deployment": {"type": "string", "description": "Deployment name, e.g. checkout"},
                "namespace": {"type": "string", "enum": NAMESPACES},
                "replicas": {"type": "integer", "minimum": 1, "maximum": 5,
                             "description": "Only for wf-scale-deployment"},
            },
            "required": ["workflow", "deployment", "namespace"],
        },
    },
    {
        "name": "collect_diagnostics",
        "description": (
            "Run the read-only AAP job template collect-diagnostics (events, pod status, logs) "
            "for an app label. No approval needed. Returns the AAP job id."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "Value of the 'app' label, e.g. checkout"},
                "namespace": {"type": "string", "enum": NAMESPACES},
            },
            "required": ["app", "namespace"],
        },
    },
]


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def aap(method, path, auth, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": auth, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read() or b"{}")
        except ValueError:
            detail = {}
        return e.code, detail


def launch(kind, name, extra_vars, auth):
    """kind: workflow_job_templates | job_templates. Returns (ok, text)."""
    st, found = aap("GET", f"/{kind}/?name={urllib.parse.quote(name)}", auth)
    if st != 200 or not found.get("results"):
        return False, f"'{name}' is not visible to this identity in AAP (HTTP {st})."
    tid = found["results"][0]["id"]
    st, res = aap("POST", f"/{kind}/{tid}/launch/", auth, {"extra_vars": extra_vars})
    if st not in (200, 201):
        return False, f"AAP refused to launch '{name}' (HTTP {st}): {json.dumps(res)[:300]}"
    job_id = res.get("workflow_job") or res.get("job") or res.get("id")
    return True, job_id


def call_tool(name, args, auth):
    if not auth.lower().startswith("bearer "):
        return True, "Missing Authorization header: the caller's AAP token is required."
    ns = args.get("namespace")
    if ns not in NAMESPACES:
        return True, f"namespace must be one of {NAMESPACES}."
    if name == "launch_remediation":
        wf, dep = args.get("workflow"), str(args.get("deployment", ""))
        if wf not in WORKFLOWS:
            return True, f"workflow must be one of {WORKFLOWS}."
        if not NAME_RE.match(dep):
            return True, "deployment must be a valid Kubernetes name."
        extra = {"namespace": ns, "deployment": dep}
        if wf == "wf-scale-deployment":
            try:
                extra["replicas"] = int(args["replicas"])
            except (KeyError, TypeError, ValueError):
                return True, "wf-scale-deployment needs replicas (1-5)."
        ok, out = launch("workflow_job_templates", wf, extra, auth)
        log(f"AUDIT launch_remediation {wf} {extra} -> {'workflow_job ' + str(out) if ok else out}")
        if not ok:
            return True, out
        return False, (f"Launched {wf} for deployment {dep} in {ns}: AAP workflow job {out}. It is "
                       f"WAITING FOR HUMAN APPROVAL in AAP; nothing has changed yet.")
    if name == "collect_diagnostics":
        app = str(args.get("app", ""))
        if not NAME_RE.match(app):
            return True, "app must be a valid label value."
        ok, out = launch("job_templates", DIAG_TEMPLATE, {"namespace": ns, "app": app}, auth)
        log(f"AUDIT collect_diagnostics app={app} ns={ns} -> {'job ' + str(out) if ok else out}")
        return (True, out) if not ok else (False, f"collect-diagnostics started: AAP job {out} (read-only).")
    return True, f"Unknown tool {name}."


def handle_rpc(msg, auth):
    mid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
    if mid is None:                       # notification (e.g. notifications/initialized)
        return None
    if method == "initialize":
        asked = params.get("protocolVersion")
        result = {"protocolVersion": asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
                  "capabilities": {"tools": {"listChanged": False}},
                  "serverInfo": {"name": "aap-actions", "version": "1.0.0"}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        is_error, text = call_tool(params.get("name"), params.get("arguments") or {}, auth)
        result = {"content": [{"type": "text", "text": text}], "isError": is_error}
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"Method not found: {method}"}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send(200, {"status": "ok"}) if self.path == "/healthz" else self._send(405)

    def do_DELETE(self):
        self._send(405)

    def do_POST(self):
        if self.path.rstrip("/") != "/mcp":
            return self._send(404)
        try:
            msg = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"null")
        except ValueError:
            return self._send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
        auth = self.headers.get("Authorization", "")
        if isinstance(msg, list):
            out = [r for r in (handle_rpc(m, auth) for m in msg) if r is not None]
            return self._send(200, out) if out else self._send(202)
        out = handle_rpc(msg, auth) if isinstance(msg, dict) else None
        return self._send(200, out) if out is not None else self._send(202)

    def log_message(self, fmt, *args):    # keep the log to AUDIT lines (no headers, no tokens)
        pass


if __name__ == "__main__":
    log(f"aap-actions listening on :8080, AAP {AAP_URL}, namespaces {NAMESPACES}")
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()

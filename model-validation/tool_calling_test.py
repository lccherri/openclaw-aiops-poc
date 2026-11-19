#!/usr/bin/env python3
"""
Model pre-validation (Phase 0): does the model pick the right tool, with the right
arguments, consistently?

Uses only the Python standard library. Talks to any OpenAI-compatible endpoint.

Environment:
  MAAS_INTERNAL_URL      base URL ending in /v1
  MAAS_INTERNAL_API_KEY  API key
  MAAS_MODEL             model id (or pass --model)

Examples:
  python3 model-validation/tool_calling_test.py --list-models
  python3 model-validation/tool_calling_test.py --model my-model --runs 5
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

# --- Fictitious tools, mirroring the POC tool surface -----------------------
TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_pods",
            "description": "List pods in a Kubernetes namespace with their status and restart count.",
            "parameters": {
                "type": "object",
                "properties": {
                    "namespace": {"type": "string", "description": "Kubernetes namespace"},
                    "label_selector": {"type": "string", "description": "Optional label selector, e.g. app=web"},
                },
                "required": ["namespace"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_logs",
            "description": "Get recent logs of a pod. Use previous=true for the last crashed container.",
            "parameters": {
                "type": "object",
                "properties": {
                    "namespace": {"type": "string"},
                    "pod": {"type": "string"},
                    "previous": {"type": "boolean", "default": False},
                    "tail_lines": {"type": "integer", "default": 100},
                },
                "required": ["namespace", "pod"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "restart_deployment",
            "description": "Request a rollout restart of a deployment. Requires human approval.",
            "parameters": {
                "type": "object",
                "properties": {
                    "namespace": {"type": "string"},
                    "deployment": {"type": "string"},
                },
                "required": ["namespace", "deployment"],
            },
        },
    },
]

SYSTEM = (
    "You are an SRE assistant operating an OpenShift cluster. "
    "Always use the provided tools to inspect or act. Call exactly one tool per turn."
)

# (prompt, expected tool, expected args subset)
SCENARIOS = [
    ("Which pods are running in the namespace demo-apps?",
     "get_pods", {"namespace": "demo-apps"}),
    ("Show me the pods of the app 'checkout' (label app=checkout) in namespace demo-apps.",
     "get_pods", {"namespace": "demo-apps", "label_selector": "app=checkout"}),
    ("Pod checkout-7d9f8-abcde in demo-apps keeps crashing. Show the logs of the previous container.",
     "get_logs", {"namespace": "demo-apps", "pod": "checkout-7d9f8-abcde", "previous": True}),
    ("Get the last 50 log lines of pod api-5c6d7-xyz12 in namespace demo-apps.",
     "get_logs", {"namespace": "demo-apps", "pod": "api-5c6d7-xyz12", "tail_lines": 50}),
    ("The deployment 'checkout' in demo-apps is stuck after a config fix. Please restart it.",
     "restart_deployment", {"namespace": "demo-apps", "deployment": "checkout"}),
]


def post(url, key, payload, timeout=120):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode()), dict(r.headers)


def list_models(base, key):
    req = urllib.request.Request(f"{base}/models", headers={"Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.loads(r.read().decode())
    for m in data.get("data", []):
        print(m.get("id"))


def args_match(expected, actual):
    for k, v in expected.items():
        a = actual.get(k)
        if isinstance(v, str):
            if not isinstance(a, str) or a.strip().lower() != v.lower():
                return False
        elif a != v:
            return False
    return True


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default=os.environ.get("MAAS_INTERNAL_URL"))
    p.add_argument("--api-key", default=os.environ.get("MAAS_INTERNAL_API_KEY"))
    p.add_argument("--model", default=os.environ.get("MAAS_MODEL"))
    p.add_argument("--runs", type=int, default=3, help="repetitions per scenario")
    p.add_argument("--threshold", type=float, default=0.8, help="minimum accuracy to pass")
    p.add_argument("--list-models", action="store_true")
    p.add_argument("--json-out", help="write detailed results to this file")
    a = p.parse_args()

    if not a.base_url or not a.api_key:
        sys.exit("Set MAAS_INTERNAL_URL and MAAS_INTERNAL_API_KEY (or use --base-url/--api-key)")
    base = a.base_url.rstrip("/")

    if a.list_models:
        list_models(base, a.api_key)
        return
    if not a.model:
        sys.exit("Set MAAS_MODEL or --model")

    results, total, tool_ok, full_ok, latencies = [], 0, 0, 0, []
    rate_headers = {}
    for prompt, exp_tool, exp_args in SCENARIOS:
        for i in range(a.runs):
            total += 1
            payload = {
                "model": a.model,
                "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}],
                "tools": TOOLS,
                "tool_choice": "auto",
                "temperature": 0,
            }
            t0 = time.time()
            try:
                resp, headers = post(f"{base}/chat/completions", a.api_key, payload)
            except urllib.error.HTTPError as e:
                body = e.read().decode(errors="replace")[:300]
                print(f"[ERROR] HTTP {e.code}: {body}")
                results.append({"prompt": prompt, "run": i, "error": f"HTTP {e.code}"})
                if e.code == 400 and "tool" in body.lower():
                    sys.exit("Endpoint rejected the 'tools' parameter - model/endpoint unsuitable")
                continue
            latencies.append(time.time() - t0)
            rate_headers = {k: v for k, v in headers.items() if "ratelimit" in k.lower()} or rate_headers

            msg = resp["choices"][0]["message"]
            calls = msg.get("tool_calls") or []
            got_tool, got_args = None, {}
            if calls:
                got_tool = calls[0]["function"]["name"]
                try:
                    got_args = json.loads(calls[0]["function"].get("arguments") or "{}")
                except json.JSONDecodeError:
                    got_args = {"_invalid_json": calls[0]["function"].get("arguments")}
            t_ok = got_tool == exp_tool
            f_ok = t_ok and args_match(exp_args, got_args)
            tool_ok += t_ok
            full_ok += f_ok
            mark = "PASS" if f_ok else ("TOOL-ONLY" if t_ok else "FAIL")
            print(f"[{mark:9}] {exp_tool:18} got={got_tool} args={json.dumps(got_args)}")
            results.append({"prompt": prompt, "run": i, "expected": exp_tool, "got": got_tool,
                            "args": got_args, "tool_ok": t_ok, "full_ok": f_ok})

    acc = full_ok / total if total else 0
    print("\n=== Summary ===")
    print(f"model:               {a.model}")
    print(f"attempts:            {total}")
    print(f"right tool:          {tool_ok}/{total}")
    print(f"right tool + args:   {full_ok}/{total}  ({acc:.0%})")
    if latencies:
        print(f"avg latency:         {sum(latencies)/len(latencies):.2f}s")
    if rate_headers:
        print(f"rate-limit headers:  {rate_headers}")
    verdict = "GO" if acc >= a.threshold else "NO-GO (try another model)"
    print(f"verdict:             {verdict} (threshold {a.threshold:.0%})")

    if a.json_out:
        with open(a.json_out, "w") as f:
            json.dump({"model": a.model, "accuracy": acc, "results": results}, f, indent=2)
    sys.exit(0 if acc >= a.threshold else 2)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Streaming tool-call argument test (gate complement to tool_calling_test.py).

OpenClaw always streams. Some serving stacks mangle streamed tool-call arguments even when the
non-streaming test passes (docs/test-log.md F-14, F-18). This test asks for one tool call per
argument shape, streams the response, reassembles the arguments and checks that they are
valid JSON:

  no_args        tool without parameters             -> must be "{}" (not "")
  string_last    last argument is a string           -> {"namespace": "demo-apps"}
  integer_last   last argument is an integer         -> {"job_id": 14}
  object_last    last argument is a nested object    -> {"id": "9", "body": {"vars": "..."}}

Usage: model-validation/streaming_args_test.py [--base-url URL] [--api-key KEY] [--model M] [--runs N]
Defaults come from MAAS_INTERNAL_URL / MAAS_INTERNAL_API_KEY / MAAS_MODEL. Standard library only.
"""
import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

SCENARIOS = {
    "no_args": ({"type": "object", "properties": {}},
                "List all namespaces of the cluster with the tool."),
    "string_last": ({"type": "object", "properties": {"namespace": {"type": "string"}}, "required": ["namespace"]},
                    "Call the tool with namespace demo-apps."),
    "integer_last": ({"type": "object", "properties": {"job_id": {"type": "integer"}}, "required": ["job_id"]},
                     "Call the tool for job 14."),
    "object_last": ({"type": "object", "properties": {
                        "id": {"type": "string"},
                        "body": {"type": "object", "properties": {"vars": {"type": "string"}}}},
                     "required": ["id", "body"]},
                    "Call the tool with id 9 and body.vars set to the JSON string {\"deployment\": \"checkout\"}."),
}


def stream_call(base, key, model, schema, prompt):
    body = {"model": model, "stream": True, "max_tokens": 2048,
            "messages": [{"role": "user", "content": prompt}],
            "tools": [{"type": "function", "function": {"name": "the_tool", "description": "Test tool", "parameters": schema}}],
            "tool_choice": "auto"}          # what OpenClaw sends ("required" takes another server path)
    req = urllib.request.Request(base.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    args, called = "", False
    with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=180) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            for c in json.loads(line[5:]).get("choices") or []:
                for tc in (c.get("delta") or {}).get("tool_calls") or []:
                    called = True
                    args += (tc.get("function") or {}).get("arguments") or ""
    if not called:
        return "no call", ""
    if not args.strip():
        return "empty", args
    try:
        json.loads(args)
        return "ok", args
    except ValueError:
        return "malformed", args


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=os.environ.get("MAAS_INTERNAL_URL"))
    ap.add_argument("--api-key", default=os.environ.get("MAAS_INTERNAL_API_KEY"))
    ap.add_argument("--model", default=os.environ.get("MAAS_MODEL"))
    ap.add_argument("--runs", type=int, default=3)
    a = ap.parse_args()
    if not (a.base_url and a.api_key and a.model):
        sys.exit("set --base-url/--api-key/--model or MAAS_INTERNAL_URL/MAAS_INTERNAL_API_KEY/MAAS_MODEL")
    worst = 0
    print(f"model={a.model} streaming=true runs={a.runs}")
    for name, (schema, prompt) in SCENARIOS.items():
        results = []
        for _ in range(a.runs):
            try:
                results.append(stream_call(a.base_url, a.api_key, a.model, schema, prompt))
            except urllib.error.HTTPError as e:          # HTTP errors count as failures
                results.append((f"HTTP {e.code}", e.read()[:80].decode(errors="replace")))
            except Exception as e:                       # network errors count as failures
                results.append((f"error {type(e).__name__}", ""))
        ok = sum(1 for s, _ in results if s == "ok")
        bad = [f"{s}: {x[:60]!r}" for s, x in results if s != "ok"]
        worst = max(worst, a.runs - ok)
        print(f"  {name:13} {ok}/{a.runs} valid" + (f"   e.g. {bad[0]}" if bad else ""))
    print("verdict:", "GO" if worst == 0 else
          "PARTIAL: avoid the failing shapes in tool schemas (see test-log F-18) or fix the serving stack")


if __name__ == "__main__":
    main()

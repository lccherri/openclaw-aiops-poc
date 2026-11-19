#!/usr/bin/env bash
# Prints the tool calls and the final answer of the most recent agent session
# (evidence for the test log), or of the session key given as $1.
source "$(dirname "$0")/lib.sh"
NS=openclaw
key="${1:-}"
[[ -n "${key}" ]] || key=$(oc -n "${NS}" exec deploy/openclaw -c gateway -- sh -c 'cd /app; node dist/index.js sessions --active 60 --json 2>/dev/null' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); s=d if isinstance(d,list) else d.get("sessions",d); s=sorted(s,key=lambda x:x.get("updatedAt",0),reverse=True); print(s[0]["key"] if s else "")')
[[ -n "${key}" ]] || die "No recent session"
out="evidence-$(date -u +%Y%m%dT%H%M%SZ)"
oc -n "${NS}" exec deploy/openclaw -c gateway -- sh -c "cd /home/node && node /app/dist/index.js sessions export-trajectory --session-key '${key}' --output ${out} --json >/dev/null 2>&1"
info "Session ${key}"
oc -n "${NS}" exec deploy/openclaw -c gateway -- node -e '
const fs=require("fs"); const d=process.env.HOME+"/.openclaw/trajectory-exports/"+process.argv[1];
for (const l of fs.readFileSync(d+"/events.jsonl","utf8").trim().split("\n")) { const e=JSON.parse(l);
  if (e.type==="assistant.message") { const m=e.data.message;
    for (const c of m.content||[]) {
      if (c.type==="toolCall") console.log("  TOOL CALL  ", c.name, JSON.stringify(c.arguments||{}).slice(0,160));
      else if (c.type==="text" && c.text.trim()) console.log("  ANSWER     ", c.text.trim().replace(/\n/g,"\n             "));
    }
    if (!(m.content||[]).length) console.log("  (empty assistant message, stopReason="+m.stopReason+", tokens="+(m.usage||{}).totalTokens+")");
  }
  if (e.type==="tool.result"||e.type==="toolResult.message") { const t=JSON.stringify(e.data).slice(0,140); console.log("  TOOL RESULT", t); }
}' "${out}"

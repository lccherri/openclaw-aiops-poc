// Sends one agent turn to the OpenClaw gateway through the hooks endpoint and waits for
// completion. Runs INSIDE the gateway container (localhost), so no network exposure is
// needed: `scripts/agent-turn.sh "<message>"`. Uses OPENCLAW_HOOKS_TOKEN from the container env.
const message = process.argv[2] ||
  "Use the kubernetes tools to list the pods in namespace demo-apps and report their status in one short paragraph.";
const body = { message, name: "Manual test turn", agentId: "main", deliver: false, waitForCompletion: true };

fetch("http://127.0.0.1:18789/hooks/agent", {
  method: "POST",
  headers: {
    "Authorization": "Bearer " + process.env.OPENCLAW_HOOKS_TOKEN,
    "Content-Type": "application/json",
    "Idempotency-Key": "manual-" + Date.now(),
  },
  body: JSON.stringify(body),
})
  .then(async (r) => console.log("HTTP", r.status, await r.text()))
  .catch((e) => { console.error("ERR", e); process.exitCode = 1; });

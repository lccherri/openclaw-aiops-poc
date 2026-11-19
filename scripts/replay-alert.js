// Replays the CURRENT firing demo-apps alert(s) to the OpenClaw Alertmanager hook, exactly as
// Alertmanager would (same payload shape), and waits for the agent run to finish. Used to
// repeat a test case without waiting for Alertmanager's repeat interval.
// Runs inside the gateway container: scripts/agent-alert.sh <alertname> <pod> [summary]
const [alertname = "DemoAppCrashLooping", pod = "", summary = ""] = process.argv.slice(2);
const labels = { alertname, namespace: "demo-apps", pod, severity: "warning", route: "aiops-agent" };
const payload = {
  version: "4", status: "firing", receiver: "demo-apps/aiops-routing/aiops-agent",
  groupLabels: { alertname, pod }, commonLabels: labels,
  commonAnnotations: { summary: summary || `Container of pod ${pod} is in CrashLoopBackOff` },
  alerts: [{ status: "firing", labels, annotations: { summary }, startsAt: new Date().toISOString() }],
};
fetch("http://127.0.0.1:18789/hooks/alertmanager", {
  method: "POST",
  headers: { "Authorization": "Bearer " + process.env.OPENCLAW_HOOKS_TOKEN, "Content-Type": "application/json",
             "Idempotency-Key": "replay-" + Date.now() },
  body: JSON.stringify(payload),
}).then(async (r) => console.log("HTTP", r.status, await r.text()))
  .catch((e) => { console.error("ERR", e); process.exitCode = 1; });

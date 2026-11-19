#!/usr/bin/env bash
# Replays an alert to the agent (see scripts/replay-alert.js) and prints the session
# trajectory (tool calls) and the agent's final answer.
# Usage: scripts/agent-alert.sh [alertname] [pod] [summary]
source "$(dirname "$0")/lib.sh"
NS=openclaw
alert="${1:-DemoAppCrashLooping}"
pod="${2:-$(oc -n demo-apps get pods --no-headers | awk '/CrashLoopBackOff|Error/ {print $1; exit}')}"
summary="${3:-Container of pod ${pod} is in CrashLoopBackOff}"
oc -n "${NS}" exec -i deploy/openclaw -c gateway -- sh -c 'cat > /home/node/replay-alert.js' < "${REPO_ROOT}/scripts/replay-alert.js"
info "Replaying ${alert} for pod ${pod}"
before=$(date -u +%s)
resp=$(oc -n "${NS}" exec deploy/openclaw -c gateway -- node /home/node/replay-alert.js "${alert}" "${pod}" "${summary}")
echo "${resp}"
run_id=$(sed -nE 's/.*"runId":"([^"]+)".*/\1/p' <<<"${resp}")
[[ -n "${run_id}" ]] || die "Hook did not accept the alert"
# hook mappings answer on admission; wait for this run to finish
until line=$(oc -n "${NS}" logs deploy/openclaw -c gateway --since=$(( $(date -u +%s) - before + 5 ))s 2>/dev/null \
      | grep "hook agent run completed runId=${run_id}" | head -1) && [[ -n "${line}" ]]; do sleep 5; done
status=$(sed -nE 's/.*runId=[^ ]+ status=([a-z]+).*/\1/p' <<<"${line}")
info "Run ${run_id} finished: status=${status}"
# hook runs get their own session: agent:main:cron:<jobId>
key=$(sed -nE 's/.*sessionKey=(agent:[^: ]+:cron:[^: ]+).*/\1/p' <<<"${line}")
"${REPO_ROOT}/scripts/agent-last-session.sh" ${key:+"${key}"}

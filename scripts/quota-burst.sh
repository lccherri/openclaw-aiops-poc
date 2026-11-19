#!/usr/bin/env bash
# Test case 5 - sends small requests with the AGENT key until MaaS answers 429,
# then proves that another consumer (OTHER_CONSUMER_MAAS_KEY) is not affected.
source "$(dirname "$0")/lib.sh"
require_cmd curl
require_env RHOAI_MAAS_URL AGENT_MAAS_KEY OTHER_CONSUMER_MAAS_KEY
MAX="${MAX_REQUESTS:-500}"

call() {  # call <key> -> prints HTTP code
  curl -sk -o /dev/null -w '%{http_code}' -m 60 "${RHOAI_MAAS_URL}/chat/completions" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "{\"model\":\"aiops-model\",\"max_tokens\":200,\"messages\":[{\"role\":\"user\",\"content\":\"Write 150 words about SRE.\"}]}"
}

start=$(date +%s); n=0; code=""
info "Bursting with the agent key (max ${MAX} requests)"
while (( n < MAX )); do
  n=$((n+1)); code=$(call "${AGENT_MAAS_KEY}")
  printf '%s request=%d http=%s\n' "$(date -u +%H:%M:%S)" "${n}" "${code}"
  [[ "${code}" == "429" ]] && break
done
elapsed=$(( $(date +%s) - start ))

if [[ "${code}" == "429" ]]; then
  ok "Agent quota enforced by MaaS after ${n} requests / ${elapsed}s (HTTP 429)"
else
  fail "No 429 after ${n} requests - check the subscription limits"
fi

other=$(call "${OTHER_CONSUMER_MAAS_KEY}")
[[ "${other}" == "200" ]] && ok "Other consumer unaffected (HTTP ${other})" || fail "Other consumer got HTTP ${other}"

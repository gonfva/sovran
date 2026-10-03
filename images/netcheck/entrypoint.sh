#!/bin/sh
# Exit criteria:
#   1) curl MODEL_HEALTH_URL succeeds
#   2) curl https://example.com fails (no internet egress)
#   3) every host in EXPECTED_HOSTS answers on 443 (its endpoint exists)
#   4) every host in BLOCKED_HOSTS does not (its endpoint was removed and stayed removed)
#
# 3 and 4 exist because Phase 6 deleted the kms/sts endpoints and gated the SSM trio on
# the grounds that nothing in the VPC calls them. That claim is only worth as much as the
# test that keeps it true — without it, a re-added endpoint is invisible until the bill
# arrives, and a wrongly-removed one is invisible until a demo fails.
set -eu

MODEL_HEALTH_URL="${MODEL_HEALTH_URL:-}"
INTERNET_URL="${INTERNET_URL:-https://example.com}"
EXPECTED_HOSTS="${EXPECTED_HOSTS:-}"
BLOCKED_HOSTS="${BLOCKED_HOSTS:-}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-10}"

# Reachability here means "something answered on 443", not "the request succeeded".
# An interface endpoint returns an HTTP error to an unsigned request, and that error is
# proof the endpoint is there. Only a connect/resolve failure means absent.
endpoint_answers() {
  # rc is seeded and assigned via || so the function is safe under `set -e` no matter
  # where it is called from, not just inside an `if`.
  rc=0
  curl -sS -o /dev/null --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME" "https://$1/" >/dev/null 2>&1 || rc=$?
  # 0 = answered, 22 = answered with an HTTP error (--fail is not set, so this is rare).
  # 6 = DNS failure, 7 = connect refused, 28 = timeout -> no endpoint.
  [ "$rc" -eq 0 ] || [ "$rc" -eq 22 ]
}

if [ -z "$MODEL_HEALTH_URL" ]; then
  echo "FAIL: MODEL_HEALTH_URL is required"
  exit 2
fi

echo "=== Phase 1 netcheck ==="
echo "model health: $MODEL_HEALTH_URL"
echo "internet url: $INTERNET_URL"

model_ok=0
internet_blocked=0

echo
echo "--- 1) model health (expect success) ---"
if curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$MODEL_HEALTH_URL"; then
  echo
  echo "PASS: model health reachable"
  model_ok=1
else
  echo
  echo "FAIL: model health not reachable"
fi

echo
echo "--- 2) public internet (expect failure) ---"
if curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$INTERNET_URL" >/dev/null 2>&1; then
  echo "FAIL: reached public internet ($INTERNET_URL)"
else
  echo "PASS: public internet not reachable (as expected)"
  internet_blocked=1
fi

endpoints_ok=1

echo
echo "--- 3) expected VPC endpoints (expect reachable) ---"
if [ -z "$EXPECTED_HOSTS" ]; then
  echo "SKIP: EXPECTED_HOSTS not set"
else
  for h in $EXPECTED_HOSTS; do
    if endpoint_answers "$h"; then
      echo "PASS: $h reachable"
    else
      echo "FAIL: $h unreachable (endpoint missing?)"
      endpoints_ok=0
    fi
  done
fi

echo
echo "--- 4) removed VPC endpoints (expect unreachable) ---"
if [ -z "$BLOCKED_HOSTS" ]; then
  echo "SKIP: BLOCKED_HOSTS not set"
else
  for h in $BLOCKED_HOSTS; do
    if endpoint_answers "$h"; then
      echo "FAIL: $h reachable (endpoint re-added? paying for it?)"
      endpoints_ok=0
    else
      echo "PASS: $h unreachable (as expected)"
    fi
  done
fi

echo
if [ "$model_ok" -eq 1 ] && [ "$internet_blocked" -eq 1 ] && [ "$endpoints_ok" -eq 1 ]; then
  echo "Phase 1 + Phase 6 exit criteria: OK"
  exit 0
fi

echo "Phase 1 + Phase 6 exit criteria: FAILED"
exit 1

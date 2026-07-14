#!/usr/bin/env bash
# Always produce a verdict file so report.sh never dies with "no verdict produced".
# Intended path in handshake-orchestration-tb2: .dynamo/generate_verdict.sh
set -euo pipefail

VERDICT_PATH="${1:-${RUNNER_TEMP:-/tmp}/verdict.md}"
RAW_PATH="${RUNNER_TEMP:-/tmp}/review_raw.txt"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RETRY_SCRIPT="${ROOT}/scripts/run_review_with_retry.sh"

mkdir -p "$(dirname "$VERDICT_PATH")"

write_fallback() {
  local reason="$1"
  cat >"$VERDICT_PATH" <<EOF
## 🤖 Automated Review

**Verdict:** FAIL

_Infra / review-runner failure — not a task content FAIL._

### Blocking Issues
- Rubric model call did not complete: ${reason}
- Downstream report received this structured fallback so the gate does not crash with "no verdict produced".

### Operator notes
- Likely Anthropic org 429 (TPM/RPM) or CLI error. Re-run when quota has headroom, or escalate model/throttle settings in handshake-orchestration-tb2.
- Default review model should be a non-Opus SKU for normal PRs; keep Opus for escalations only.

EOF
}

if [[ ! -x "$RETRY_SCRIPT" && -f "$RETRY_SCRIPT" ]]; then
  chmod +x "$RETRY_SCRIPT" || true
fi

set +e
bash "$RETRY_SCRIPT" >"$RAW_PATH" 2>"${RUNNER_TEMP:-/tmp}/generate_verdict.err"
status=$?
set -e

if [[ $status -eq 0 ]] && [[ -s "$RAW_PATH" ]] && grep -qE '^\*\*Verdict:\*\*' "$RAW_PATH"; then
  cp "$RAW_PATH" "$VERDICT_PATH"
  exit 0
fi

# Soft path: model wrote something without a Verdict line — keep body, append FAIL gate.
if [[ -s "$RAW_PATH" ]]; then
  {
    cat "$RAW_PATH"
    echo
    echo '**Verdict:** FAIL'
    echo
    echo '_Appended by generate_verdict.sh: model output lacked a Verdict line._'
  } >"$VERDICT_PATH"
  exit 0
fi

reason="exit=${status}"
if [[ $status -eq 42 ]]; then
  reason="Anthropic rate limit (429) after retries"
elif [[ -s "${RUNNER_TEMP:-/tmp}/generate_verdict.err" ]]; then
  reason="$(tr '\n' ' ' <"${RUNNER_TEMP:-/tmp}/generate_verdict.err" | head -c 400)"
fi

write_fallback "$reason"
# Exit 0 so the report step can post the sticky comment; the Verdict: FAIL still fails the gate.
exit 0

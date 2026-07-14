#!/usr/bin/env bash
# Retry wrapper for Claude rubric review calls that hit Anthropic 429 TPM/RPM.
# Intended path in handshake-orchestration-tb2: scripts/run_review_with_retry.sh
set -euo pipefail

MAX_RETRIES="${MAX_RETRIES:-6}"
BASE_DELAY="${BASE_DELAY:-2}"
# Default to a lighter model for normal PRs; override with REVIEW_MODEL / DYNAMO_REVIEW_MODEL.
MODEL="${REVIEW_MODEL:-${DYNAMO_REVIEW_MODEL:-claude-sonnet-4-5}}"
SETTINGS="${REVIEW_SETTINGS:-.dynamo/settings.json}"
PROMPT_FILE="${REVIEW_PROMPT:-.dynamo/dynamo-eval-prompt.md}"
LOG_FILE="${REVIEW_LOG:-${RUNNER_TEMP:-/tmp}/review_attempt.log}"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "::error::Set the ANTHROPIC_API_KEY repo/org secret (project-pays key)." >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "::error::Missing review prompt: $PROMPT_FILE" >&2
  exit 1
fi

attempt=1
delay="$BASE_DELAY"
while (( attempt <= MAX_RETRIES )); do
  echo "::notice::Claude review attempt ${attempt}/${MAX_RETRIES} model=${MODEL}"
  set +e
  # Capture stderr for 429 detection; stdout is the verdict body.
  claude -p \
    --model "$MODEL" \
    --settings "$SETTINGS" \
    --permission-mode dontAsk \
    < "$PROMPT_FILE" \
    >"${RUNNER_TEMP:-/tmp}/review_stdout.txt" \
    2>"$LOG_FILE"
  status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    cat "${RUNNER_TEMP:-/tmp}/review_stdout.txt"
    exit 0
  fi

  err="$(cat "$LOG_FILE" 2>/dev/null || true)"
  if grep -Eiq '429|rate limit|rate_limit|TPM|tokens per minute|requests per minute' <<<"$err"; then
    if (( attempt == MAX_RETRIES )); then
      echo "::error::Anthropic rate limit after ${MAX_RETRIES} attempts (model=${MODEL})." >&2
      echo "$err" >&2
      exit 42
    fi
    # Cap sleep so CI doesn't hang forever; jitter reduces synchronized stampedes.
    jitter=$(( RANDOM % (delay + 1) ))
    sleep_for=$(( delay + jitter ))
    if (( sleep_for > 120 )); then sleep_for=120; fi
    echo "::warning::429/rate-limit on attempt ${attempt}; sleeping ${sleep_for}s then retrying."
    sleep "$sleep_for"
    delay=$(( delay * 2 ))
    if (( delay > 60 )); then delay=60; fi
    attempt=$(( attempt + 1 ))
    continue
  fi

  echo "::error::Claude review failed (non-rate-limit). model=${MODEL} exit=${status}" >&2
  echo "$err" >&2
  exit "$status"
done

exit 42

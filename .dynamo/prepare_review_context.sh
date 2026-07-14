#!/usr/bin/env bash
# Shrink agent-visible context before Claude reads submission/ (cuts TPM 429 risk).
# Intended path: .dynamo/prepare_review_context.sh
set -euo pipefail

SUBMISSION="${1:-submission}"
MAX_FILE_BYTES="${MAX_FILE_BYTES:-80000}"
MAX_FILES="${MAX_FILES:-80}"

if [[ ! -d "$SUBMISSION" ]]; then
  echo "::warning::No ${SUBMISSION}/ tree; skipping context trim."
  exit 0
fi

rm -rf \
  "${SUBMISSION}/jobs" \
  "${SUBMISSION}/task/jobs" \
  "${SUBMISSION}/node_modules" 2>/dev/null || true

find "$SUBMISSION" -type d -name '.pytest_cache' -prune -exec rm -rf {} + 2>/dev/null || true
find "$SUBMISSION" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

while IFS= read -r -d '' f; do
  tmp="${f}.trimmed"
  head -c "$MAX_FILE_BYTES" "$f" >"$tmp"
  printf '\n\n…[truncated by prepare_review_context.sh at %s bytes]…\n' "$MAX_FILE_BYTES" >>"$tmp"
  mv "$tmp" "$f"
  echo "::notice::Truncated ${f} to ${MAX_FILE_BYTES} bytes"
done < <(find "$SUBMISSION" -type f \( \
  -name '*.jsonl' -o -name '*.json' -o -name '*.md' -o -name '*.py' -o -name '*.txt' \
\) -size +"${MAX_FILE_BYTES}c" -print0 2>/dev/null | head -z -n 200 || true)

count="$(find "$SUBMISSION" -type f | wc -l | tr -d ' ')"
if (( count > MAX_FILES )); then
  echo "::warning::submission has ${count} files (>${MAX_FILES}); consider stronger sparse checkout in workflow."
fi

echo "prepare_review_context: done (files≈${count})"

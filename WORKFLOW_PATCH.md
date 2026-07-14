# Apply in `handshake-project-dynamo/handshake-orchestration-tb2`

Observed `main` SHA when this patch was written: `260ddd09396754783cda522cfc1e0a52cb404c03`.

## Why

Stage 2 currently runs (from CI logs):

```bash
claude -p \
  --model claude-opus-4-8 \
  --settings .dynamo/settings.json \
  --permission-mode dontAsk \
  < .dynamo/dynamo-eval-prompt.md \
  | tee "$RUNNER_TEMP/verdict.md"
```

On Anthropic org 429 the step exits 1 with an empty/missing verdict, then:

```bash
bash .dynamo/report.sh "$RUNNER_TEMP/verdict.md"   # → "no verdict produced"
```

## Files to add

Copy from this pack into the orchestration repo root:

| Pack path | Repo path |
| --- | --- |
| `scripts/run_review_with_retry.sh` | `scripts/run_review_with_retry.sh` |
| `.dynamo/generate_verdict.sh` | `.dynamo/generate_verdict.sh` |
| `.dynamo/prepare_review_context.sh` | `.dynamo/prepare_review_context.sh` |

```bash
chmod +x scripts/run_review_with_retry.sh \
         .dynamo/generate_verdict.sh \
         .dynamo/prepare_review_context.sh
```

## Edit `.github/workflows/dynamo-review.yml` (Stage 2 job)

**Before Stage 2**, after the PR head checkout into `submission/`:

```yaml
- name: Prepare review context (trim TPM load)
  run: bash .dynamo/prepare_review_context.sh submission
```

**Replace** the direct `claude -p … | tee` Stage 2 step with:

```yaml
- name: Stage 2 — read-only rubric review (project key)
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    # Normal PRs: Sonnet. Set org/repo variable DYNAMO_REVIEW_MODEL=claude-opus-4-8 to escalate.
    REVIEW_MODEL: ${{ vars.DYNAMO_REVIEW_MODEL || 'claude-sonnet-4-5' }}
    MAX_RETRIES: "6"
    BASE_DELAY: "2"
  run: bash .dynamo/generate_verdict.sh "$RUNNER_TEMP/verdict.md"
```

Leave the existing report step unchanged:

```yaml
- name: Report + gate (FAIL verdict → red check)
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    # … existing REPO / PR_NUMBER …
  run: bash .dynamo/report.sh "$RUNNER_TEMP/verdict.md"
```

`generate_verdict.sh` always writes a `**Verdict:** …` file, so `report.sh` can post a sticky comment even after exhausted 429 retries. The gate still goes red on `FAIL`.

## Deep review (same failure mode)

If deep review also shells out to `claude` / leaves an empty `automated-review.md`, wrap that call the same way (or call `generate_verdict.sh` with `REVIEW_PROMPT` pointed at the deep-review prompt). The fail-closed filler that writes “produced no output” should only run when the file is empty *and* the wrapper was skipped.

## Token-load knobs

1. Default model → `claude-sonnet-4-5` (Opus only via `vars.DYNAMO_REVIEW_MODEL`).
2. `prepare_review_context.sh` truncates giant jsonl/md and drops `jobs/`.
3. Optional: tighten `.dynamo/settings.json` allowlist so Claude cannot scrape entire AOI dumps.

## Verify

Re-run Dynamo Review on any PR that previously failed with:

```
API Error: Request rejected (429) … claude-opus-4-8
no verdict produced
```

Expect either a real rubric verdict, or a structured infra FAIL sticky (never a missing-file crash).

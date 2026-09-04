# Handoff: fm-done-means-verified-v1

Written because context was about to compact. Re-read this before acting.
A claim you cannot re-derive is not a record.

## Where things stand

PR: https://github.com/kunchenguid/firstmate/pull/3683
Branch `fm/fm-done-means-verified-v1`, pushed to the **ICGNU3 fork** (upstream
`kunchenguid` denies this machine's `ICGNU3` credential, so the pipeline's push
step fails; the fork is the sanctioned path and `AGENTS.md` recognises it).
The no-mistakes run is terminal (failed at `push`); custody is returned and the
branch is mine. `review`, `test`, `document`, `lint` all completed before it.

Full PR body draft lives OUTSIDE the repo at:
`<session scratchpad>/pr-body.md` - it holds the proxy ledger, the twin table,
the three-state section, the follow-ups. If it is gone, the PR body on 3683 is
already the published copy; edit that.

## The two hard rules (captain, stricter than the review findings)

**RULE ONE.** A run may produce `verified` only when it reached a terminal,
successful, **accepted** outcome. Not running is not verified. Not
failed-but-explained is not verified. Terminal AND successful AND accepted, all
three, **gating the verdict** rather than appearing in its explanation.

**RULE TWO.** A verdict must be **bound to the exact PR head SHA it evaluated**.
Any new commit on that PR automatically makes the verdict **stale**, and stale
**BLOCKS** cleanup until verification runs again. Not a warning, not a downgrade
to `unverified`. Bind the SHA into the verdict record so the binding cannot be
forgotten, and make the staleness test a comparison against the **live** head
rather than a cached fact.

## The two P1 findings these come from

1. `bin/fm-verify-done.sh`, end of the validated-commit arm: `RUN_OUTCOME` and
   `RUN_STATUS` were read and used only in the explanation string before
   `verdict_is verified`, so a still-running or failed run still verified.
   Verdict and narration coming apart, in the top-level verifier.
2. `bin/fm-teardown.sh` claim gate (~line 2650): a standing `verified` verdict
   was trusted without re-comparing the live head, so an open PR force-pushed or
   given another commit after verification let cleanup delete local evidence
   while the PR shipped an unclaimed, unvalidated commit. This is the THIRD
   STATE (the world changed) built for merges and not applied to a moving PR.

## Files touched this round, and what remains

Touched (uncommitted at time of writing):
- `bin/fm-verify-done.sh` - RULE ONE gate added after the head comparison
  (`fm_nm_run_is_active` -> unverified; `failed` -> contradicted; `cancelled`
  and unrecognised -> unverified). **STILL TOO LOOSE for RULE ONE**: it accepts
  `completed` as well as `passed`/`checks-passed`. Tighten to accepted outcomes
  only, so a bare `completed` status with no accepted outcome is NOT verified.
- `bin/fm-teardown.sh` - gate now always runs the verifier and lets a standing
  verified record rescue ONLY rc=3 (absence), never rc=4.
- `bin/fm-done-claim-lib.sh` - verdict record bumped to `fm-done-verdict-v2`
  with a sixth line carrying the evaluated PR head; `fm_done_verdict_read`
  tolerates v1 (empty binding) and exports `FM_DONE_VERDICT_EVALUATED_HEAD`.
- `tests/fm-done-verified.test.sh` - plants for the run-outcome gate (unfinished
  -> not verified; failed -> contradicted; cancelled -> unverified; accepted ->
  verified). Both proven to fail without the fix.
- `tests/fm-teardown.test.sh` - plant: a standing verdict does not survive the
  head moving. Proven to fail without the fix.

Remaining:
- Tighten RULE ONE to accepted outcomes only (`passed`, `checks-passed`).
- Have `bin/fm-verify-done.sh` PASS the evaluated PR head to
  `fm_done_verdict_write` (sixth argument) so the binding is actually recorded.
- Implement RULE TWO's staleness properly: when the PR's live head differs from
  the standing verdict's evaluated head, record/report **`stale`** (not
  `contradicted`) and make the teardown gate BLOCK on it with its own message.
  Distinguish: no standing verdict + head mismatch = `contradicted` (the
  fabricated-claim case, must stay); standing verified verdict evaluated at the
  claimed head + PR moved = `stale`.
- Plants required: a verified claim against an unfinished run must be refused;
  a verdict whose PR head then moves must go stale and block.
- Re-run: `bin/fm-lint.sh`, `tests/fm-done-verified.test.sh`,
  `tests/fm-teardown.test.sh`, `tests/fm-crew-state.test.sh`,
  `tests/fm-captain-hold-lifecycle.test.sh`, `tests/fm-pr-check-security.test.sh`.
- Commit, push to `ICGNU3`, report as
  `done: pr=<url> head=<full-sha> - <one line>` with `head=` READ BACK FROM THE
  FORGE, never from what you believe you pushed.

## The failed CI check, identified (not guessed)

`gh pr checks 3683 --repo kunchenguid/firstmate` -> **Greptile Review: fail**.
It is the automated reviewer reporting the two P1 findings above; there is no
separate failing test job. Fixing the two findings is what clears it.

## Known-pre-existing local test failures (A/B proven vs baseline 3d2a08b)

`fm-composer-lib` (half-block rule), `fm-wake-queue` (subshell hold),
`fm-muse-harness` (process detection), `fm-teardown` (herdr-preflight-missing-adapter).
Same assertion and exit code on both sides of this change; all look macOS-local.
Plus one load artifact: `fm-pr-check-security` can fail with
`first merged watcher cycle failed` and EMPTY stderr under full-suite load,
because `run_watcher_bounded` wraps a real watcher in a perl `alarm 10` and
exits 124 on a TERM kill. It passes standalone at the same commit.

## Captain instruction, verbatim - DO NOT ACT ON THE FILE

> "Finish and verify the two verifier fixes first. Leave
> NVIDIA_BUILD_EVALUATION.md untouched. Once the verifier change is safely
> committed, report the file location, contents, apparent owner or origin, and
> whether it overlaps the planned Kimi K3 integration. Do not refresh, clean,
> delete, relocate, or overwrite the file. We will incorporate it deliberately
> when we resume the NVIDIA thread."

File: `/Users/werhiz/firstmate/projects/rhizprotocol/docs/operational/research/NVIDIA_BUILD_EVALUATION.md`
Untracked, outside this worktree. **READ ONLY.** Do not run any refresh, sync,
clean, or checkout that could touch it. Sequence matters: verifier fixes
committed FIRST, then the report.

## Convergence rule in force

Fix only what review finds wrong in the code that already exists. No scope
extension, no volunteered safety constraints, no belt-and-braces - three of five
findings in one earlier round came from exactly that instinct. Anything real but
not required for this change to be correct becomes a named follow-up in the PR
body, not a commit.

# gitperms — workflow

Repo-specific workflow policy. Anything not stated here comes from the global
config; this file records only what is genuinely specific to gitperms.

## Follow-up tracking

**`tracker: github`**

Captured follow-ups become **GitHub issues** via `gh`, not entries in a
planning file. This repo has tracked its work as issues since 2013 and has no
`TODO.md`; a planning doc arrives with the documentation phase, and issues
remain the destination for captured follow-ups regardless.

## Orchestration policy

**`team-managed: enabled`**

This repo is run under the team-of-roles model: the main-thread session is the
**Project-Manager seat** and dispatches substantive edits — the Perl source
(`handle_metadata`), the shell installer (`setup`), tests, and documentation —
to the owning role-subagent (**backend-developer** for code and tests,
**writer** for documentation, **config-engineer** for operating config) rather
than authoring them directly. The orchestrator keeps planning, review,
CI/config wiring, and integration.

The `team-managed-delegation.py` PreToolUse hook backstops this as a **nudge**:
an advisory reminder that still allows the edit. Subagents edit freely;
config / CI / lockfiles, plan files, agent memory, and untracked scratch are
exempt.

Unlike `auto-merge`, this sentinel is read from the **working tree**, so it
takes effect as soon as it lands on `master` and the checkout is updated.

## Branch protection

`master` is protected by the **Protect Master Branch** ruleset, whose applied
JSON is kept at `.github/rulesets/protect-master.json`. Currently active:

- `deletion` — branch deletion blocked.
- `non_fast_forward` — force-push blocked.
- `pull_request` — PR required; 0 approvals, review threads must resolve,
  **squash-only** merges.

**`required_status_checks` is deliberately absent.** The repo has no CI yet,
and a required check that never reports blocks every merge. The checks are
added once CI exists, using the context names CI actually produces.

Layer 2 (the `no-commit-to-branch` pre-commit hook) and therefore layer 3 (the
edit-time `branch-protection.py` guard, which activates only where layer 2 is
configured) are **not yet in place** — they arrive with the pre-commit
baseline.

## Sentinels deliberately not declared

Recorded so each is revisited when its precondition is met, rather than
forgotten:

| Sentinel | Precondition |
|----------|--------------|
| `auto-merge: enabled` | Green CI. It exists to skip the manual merge gate *because* server-side checks make it redundant — with no CI it would remove the gate and substitute nothing. Note it is read from the **default branch**, so it applies from the PR *after* the one that adds it, and adopting it implies `deleteBranchOnMerge` (already enabled). |
| `resolve-task: autonomous` | Green CI. |
| `merge-finalization: enforce` | A planning doc carrying `[x]` items; none exists yet. |

## Versioning & tagging

Method: **`repo`** — the whole repo versions as one unit, tags `vX.Y.Z`,
annotated, cut at the merge commit on `master`.

The modernization is a **breaking change** — the git-notes format moves from
YAML to JSON with no migration path, and the pre-takeover code is preserved on
the `legacy` branch. It ships as `v2.0.0`.

Version tags also serve pre-commit consumers, who pin `rev:` to a tag when
using this repo as a hook source.

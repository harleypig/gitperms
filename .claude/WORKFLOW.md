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
**Project-Manager seat** and dispatches substantive edits to the owning
role-subagent rather than authoring them directly. The norm itself, the
`team-managed-delegation.py` nudge hook, and the exempt set (config/CI,
lockfiles, plan files, agent memory, untracked scratch) are defined in the
global `team-managed-delegation.md` — not restated here.

What *is* specific to gitperms is which file belongs to which seat:

| Path | Owning role |
|------|-------------|
| `handle_metadata` — the Perl tool | backend-developer |
| `setup` and the git hooks (`post-commit`, `post-checkout`, `post-merge`) | backend-developer |
| tests | backend-developer |
| `README` and user-facing documentation | writer |
| `.claude/`, `.github/rulesets/`, hook specs | config-engineer |

The orchestrator keeps planning, review, CI/config wiring, and integration.

This sentinel is read from the **working tree**, not the default branch — so
it takes effect as soon as it is on disk, **including on the branch that adds
it**. (That is the deliberate departure from `auto-merge`, which *is* read
from the default branch.)

## Branch protection

`master` is protected by the **Protect Master Branch** ruleset. The applied
JSON at [`.github/rulesets/protect-master.json`][ruleset] is the record of
*what* is enforced — read it rather than a copy kept in step by hand. Only
layer 1 (server-side) is in place; layers 2 and 3 are tracked in [#10][i10].

What the JSON cannot say — the repo-specific reasoning:

**`required_status_checks` is deliberately absent.** When the ruleset was
applied the repo had no CI at all, and a required check that never reports
blocks every merge. With `bypass_actors: []` there is no escape short of
editing the ruleset through the API, so adopting the house template's
inherited check list would have wedged the repo outright.

CI now exists (`.github/workflows/ci.yml`), and the contexts it produces are
exactly:

- `perlcritic`
- `tier1`

Both are job names, which is what GitHub Actions reports as the check context.
Tier 2 (the Perl version matrix) and tier 3 (the privileged container) have
runners but no tests yet and therefore no job, so they contribute **no**
context — do not require one for them until they do, or the ruleset wedges for
the same reason the template would have.

Adding these to the ruleset is [#10][i10].

To change the ruleset, edit the JSON and re-apply it. Plain `gh` uses the
stored OAuth credential, which has the admin rights this needs:

```bash
gh api repos/harleypig/gitperms/rulesets/20078758 \
  --method PUT --input .github/rulesets/protect-master.json
```

## Deferred work — decided, tracked, not forgotten

Each row is a deliberate deferral: the decision and its precondition are
recorded here, and the tracked issue carries the full reasoning and the
acceptance criteria. The first three are **sentinels deliberately not
declared**; the rest are protection work waiting on the same preconditions.

| Deferred | Precondition | Tracked |
|----------|--------------|---------|
| `auto-merge: enabled` | Green CI. It exists to skip the manual merge gate *because* server-side checks make it redundant — with no CI it would remove the gate and substitute nothing. Read from the **default branch**, so it applies from the PR *after* the one that adds it; adopting it implies `deleteBranchOnMerge` (already enabled). | [#11][i11] |
| `resolve-task: autonomous` | A **test suite** — not merely CI reporting. The sentinel lets trivial tasks land without an ask gate once CI is green, which is only meaningful if green means something. Also read from the **default branch**. | [#11][i11] |
| `merge-finalization: enforce` | A planning doc carrying `[x]` items; none exists yet. | [#11][i11] |
| `required_status_checks`, plus protection layers 2 (`no-commit-to-branch`) and 3 (`branch-protection.py`, which activates automatically once layer 2 is configured) | CI producing real context names, and a `.pre-commit-config.yaml` for layer 2. | [#10][i10] |
| A tag-protection ruleset over `refs/tags/v*` (deletion, force-update) | `v2.0.0` being cut — there is nothing to protect until a tag exists, and a tag here is a distribution artifact (pre-commit consumers pin `rev:`). | [#12][i12] |

Versioning and tagging policy lives in [`CONVENTIONS.md`][conv], where the
**release-tag** skill reads it.

[ruleset]: ../.github/rulesets/protect-master.json
[conv]: CONVENTIONS.md
[i10]: https://github.com/harleypig/gitperms/issues/10
[i11]: https://github.com/harleypig/gitperms/issues/11
[i12]: https://github.com/harleypig/gitperms/issues/12

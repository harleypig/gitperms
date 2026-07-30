# gitperms — conventions

Repo-specific conventions. Anything not stated here comes from the global
config; this file records only what is genuinely specific to gitperms.

## Versioning & tagging

The global `git.md` *Versioning & tags* requires four things of a repo: the
**method**, the **tag pattern**, the **bump policy**, and **what pushing a tag
triggers**. All four, plus the signing posture:

- **Method:** `repo` — the whole repo versions as one unit. There are no
  independently deployable subtrees to version separately.
- **Tag pattern:** `vX.Y.Z`, semver, **annotated**, cut at the merge commit
  on `master`. A pushed tag is never moved, re-pointed, or deleted; a mistake
  gets a new tag.
- **Signing:** **unsigned** — the global default. Annotated tags already
  record authorship, and nothing downstream verifies tag provenance.
- **Bump policy:** the surface under the compatibility promise is the
  **git-notes format**, the `handle_metadata` CLI, and the **hook contract**
  a consumer installs (`setup` plus the `post-*` hooks). Within a stable
  major: **MAJOR** for a breaking change to any of those three, **MINOR** for
  a backward-compatible addition, **PATCH** for a fix. A change that ships no
  consumable artifact — CI, agent config, meta — gets **no tag** at all.
  (Which line the versions run on is still open; see *The modernization
  version* below.)
- **What pushing a tag triggers: nothing, in this repo.** There is no release
  workflow, no publish step, and no artifact build — pushing a tag only
  creates the ref. That is worth stating rather than leaving unsaid, because
  `git.md` tells the agent to treat a tag push as outward-facing and confirm
  first; knowing that nothing fires here is what makes the confirmation cheap
  rather than fraught.

  The real consequence is **downstream, and delayed**: pre-commit consumers
  pin `rev:` to a tag, and pre-commit clones this repo *at that tag* to run
  `handle_metadata`. A tag is therefore a **distribution artifact** — which
  is why tag protection is tracked ([#12][i12]) rather than assumed.

### The modernization version — intended, not committed

The modernization is a **breaking change**: the git-notes format moves from
YAML to JSON with no migration path, and the pre-takeover code is preserved
on the `legacy` branch. **`v2.0.0` is the intended version** for it.

It is **not a committed decision**. The tag does not land until the
modernization is ready to ship, so the version sits in limbo until then and
this entry records the *intent*, not a choice already made.

### OPEN — decided when the tag is actually cut

> **Question for the operator: should the modernization's first tag be
> `v2.0.0`, or should the line start at `v0.y.z` and reach `1.0.0`
> deliberately?**
>
> Tagging `v2.0.0` as the first tag **skips the `v0` alpha line entirely**,
> so strict semver binds from tag one — every later breaking change needs a
> major bump, with no loose pre-stable window to iterate in. The global
> `git.md` *Versioning & tags* is explicit that the `0 → 1` stability crossing
> is "a major decision in its own right" that must be "crossed on purpose,
> never by accident" — and jumping straight to `v2.0.0` crosses it
> **implicitly**, as a side effect of picking a number that reads as "the
> successor to the pre-takeover code."
>
> Both readings are defensible, and **neither is chosen here**:
>
> - **`v2.0.0` directly** — the `2` tells anyone pinning a `rev:` that this
>   is not the 2013 code, and the tool's surface is small and long-stable,
>   so the compatibility promise is one this repo can plausibly keep from
>   day one.
> - **`v0.y.z` first** — the modernization is a rewrite whose interface is
>   expected to move; `v0` is exactly the window for that, and the stability
>   crossing then happens on purpose, as its own decision.
>
> **This is unresolved on purpose.** The operator answers it at the moment
> the tag is cut; do not pick a side and tag on your own judgment. When it is
> answered, replace this block with the decision and its reasoning.

## Quality assurance & tests — documents not yet written

Neither a QA doc nor a `TESTS.md` exists yet, and neither is tracked by an
issue of its own — recorded here so the absence reads as a known gap rather
than an oversight.

`qa.md` requires a repo QA doc that gives **every** QA dimension an explicit
status (Active / Planned / Off / N/A), and a dimension with no entry is itself
a QA defect — so today the whole doc is the defect. The repo has no CI, no
test suite, and no formatter/linter gate; `.perlcriticrc` and `.perltidyrc` at
the repo root are the only tool configs present. Both docs arrive with the CI
and pre-commit baseline that [#10][i10] waits on.

Until they exist, a QA pass falls back down the **qa-check** discovery
precedence: no `.claude/` QA doc and no doc-index-named one, so derive the
pipeline from the detected tooling, and failing that run `qa.md`'s generic
pipeline against whatever is present.

[i10]: https://github.com/harleypig/gitperms/issues/10
[i12]: https://github.com/harleypig/gitperms/issues/12

<!--
SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
SPDX-License-Identifier: CC-BY-4.0
-->

# Contributing

> The authoritative, org-wide version of all of this is the [ParkviewLab handbook](https://github.com/ParkviewLab/handbook/tree/main).

This repo follows the ParkviewLab conventions. The essentials:

## Branch & PR flow

- Branch off `develop` into an ephemeral worktree named with a prefix: `feature-`, `bug-`/`fix-`, `doc-`, `test-`, `ops-`, `ci-`, `build-`, `release-` (hyphen, not slash). See the handbook's `branching.md`.
- Open a PR into `develop`. The repo is merge-commit only, so the merge button can only make a merge commit; merging is the maintainer's action.
- Releases are cut from `main` via the CLI (`git merge --no-ff develop`, then bump + tag), not a PR, and end with the back-merge pull request from `back-merge-<tag>`, which `git back-merge` opens, checks and merges. See the handbook's `releases.md`.

## Commit / PR-title convention (this is what the changelog reads)

Because a PR is merged with a merge commit titled `<PR title> (#N)`, the PR title becomes the commit subject, and the changelog is generated from it (by dev-tools' shared `generate-changelog`, which lists every merged PR by its title, under the group its type names). Prefix every PR title with a [Conventional Commit](https://www.conventionalcommits.org/) type:

| Title | Group in the notes | Notes |
|---|---|---|
| any type with `!` after it (`feat!:`), or a breaking-change footer | Breaking changes | listed there once, whatever its type |
| `feat:` | Features | user-visible |
| `fix:` | Bug fixes | user-visible |
| `perf:` | Performance | user-visible |
| `refactor:` | Refactor | |
| `docs:` | Docs | |
| `test:` | Tests | |
| `revert:` | Reverts | GitHub's Revert button titles a PR `Revert "…"`, which has no type |
| `build:` / `chore:` / `ci:` / `style:` | Maintenance | |
| any other title | Other changes | the whole title |
| a commit with no pull request | Direct commits | its subject and short hash |

A `BREAKING CHANGE:` footer belongs in the PR's description, which becomes the merge commit's message. A title without a recognised type is listed under Other changes, where its place says nothing about what kind of change it is. So: prefix it. See the handbook's `commits-and-changelogs.md`.

## Local checks before opening a PR

Run the same checks CI requires, so the PR is green on arrival:

```bash
./build.sh
uvx --from "reuse[charset-normalizer]" reuse lint
```

A PR can't be merged until the required checks pass on a branch up to date with `develop` (the build, REUSE, the version guard; see the handbook's `ci.md`); administrators are bound too. Push the branch when it is created, then after each commit.

## Versioning

The version lives in `VERSION.txt` only; never hard-code it elsewhere, and never type it on a `git tag` line: use `git bump` / `git release` from [`dev-tools`](https://github.com/ParkviewLab/dev-tools). See `releases.md`.

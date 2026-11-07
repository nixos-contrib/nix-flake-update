# nix-flake-update

[![CI](https://github.com/nixos-contrib/nix-flake-update/actions/workflows/ci.yml/badge.svg)](https://github.com/nixos-contrib/nix-flake-update/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A GitHub Action that keeps a Nix flake up to date:

1. **Updates `flake.lock`**, all of its inputs or the ones you name.
2. **Repairs the fixed-output hashes** (`vendorHash`, `cargoHash`,
   `npmDepsHash`, or any other) that the update, or a dependency bump,
   leaves stale.
3. **Delivers the result** as a pull request, as a push to the checked-out
   branch, or not at all.

Each step is optional, so the same action covers a scheduled `flake.lock`
update, the hash repair on a Dependabot pull request, or both together: the
lock update opens one pull request that already builds.

It is a drop-in replacement for
[`DeterminateSystems/update-flake-lock`](https://github.com/DeterminateSystems/update-flake-lock):
it takes the same inputs and reports the same outputs, apart from GPG signing
and `push-to-fork`, runs no third-party actions, and can also repair the
hashes the update breaks.

## Usage

### Update `flake.lock` with a pull request

```yaml
name: Update Flake Lock

on:
  schedule:
    - cron: "0 0 * * 1"
  workflow_dispatch:

jobs:
  update:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    timeout-minutes: 30
    steps:
      - name: Generate App token
        id: app-token
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.APP_CLIENT_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}

      - name: Checkout
        uses: actions/checkout@v7

      - name: Install Nix
        uses: DeterminateSystems/nix-installer-action@v23

      - name: Update flake.lock
        uses: nixos-contrib/nix-flake-update@v1
        with:
          token: ${{ steps.app-token.outputs.token }}
          pr-title: "chore(flake): update flake.lock"
          pr-labels: dependencies
          auto-merge: true
```

Add `repair-hashes: true` and the `installables` that build your packages to
fix the hashes in the same pull request.

### Repair the hash on a Dependabot pull request

```yaml
name: Update Dependency Hash

on:
  pull_request:
    paths: [go.mod, go.sum]

jobs:
  update:
    if: github.event.pull_request.user.login == 'dependabot[bot]'
    runs-on: ubuntu-latest
    permissions:
      contents: read
    timeout-minutes: 30
    steps:
      - name: Generate App token
        id: app-token
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ secrets.APP_CLIENT_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}

      - name: Checkout
        uses: actions/checkout@v7
        with:
          ref: ${{ github.head_ref }}
          token: ${{ steps.app-token.outputs.token }}

      - name: Install Nix
        uses: DeterminateSystems/nix-installer-action@v23

      - name: Update dependency hash
        uses: nixos-contrib/nix-flake-update@v1
        with:
          update-lock: false
          repair-hashes: true
          delivery: push
          commit-msg: "chore(nix): update dependency hash"
```

For Rust, trigger on `paths: [Cargo.lock]`; for npm, on `paths: [package-lock.json]`.

Three things this workflow depends on:

- **A token that triggers workflows.** A push made with `GITHUB_TOKEN` starts
  no workflow runs, so CI would not rerun on the fixed commit. Use a GitHub App
  token, as above, or a personal access token. With `delivery: push`, the
  action pushes with the credentials `actions/checkout` configured.
- **Dependabot secrets.** Workflows Dependabot triggers cannot read Actions
  secrets. Store `APP_CLIENT_ID` and `APP_PRIVATE_KEY` as Dependabot secrets,
  at the organization or repository level.
- **The branch, not the merge commit.** `actions/checkout` checks out the
  pull request's merge commit by default, a detached `HEAD` with nowhere to
  push. Pass `ref: ${{ github.head_ref }}`.

Pair it with a ruleset that requires the build check on the default branch,
so a pull request whose hash could not be repaired waits instead of merging.

## How it works

### Update the lock

`nix flake update` runs in `path-to-flake-dir`, with the `inputs` you name or
all of them. Nix reports each input that moved, and the pull request body and
the commit message carry that report.

### Repair the hashes

1. Builds the installables. If the build succeeds, there is nothing to do.
2. For each `hash mismatch in fixed-output derivation` error, it takes the
   `specified` hash and finds the one `.nix` file that holds it, then writes
   the `got` hash over it, in the same encoding (SRI, nix32, base16 or base64).
3. Builds again, in case a fixed-output derivation was only reachable once
   another one built, until the build succeeds.

   If the old hash's output is already in the store, because it was built
   before the bump or fetched from a binary cache, Nix reuses it. The build
   then fails later, for example with `go: inconsistent vendoring`, instead of
   on the hash. So when a build fails with no hash mismatch, the action
   rebuilds the fixed-output derivations whose hashes are written in the
   repository, using `--rebuild`, which brings the mismatch back.

The hash is found by value, not by attribute name, so it needs no
configuration per repository. Anything else that breaks the build fails the
run, as does a hash it cannot place:

- one that is computed, rather than written out as a string;
- one shared by several derivations, such as a single `lib.fakeHash`
  placeholder: give each its own;
- one that belongs to another flake input.

### Deliver

With `delivery: pull-request`, the changes are committed to `branch`, which is
rebuilt from the base on every run, and a pull request is opened from it:

- The branch is pushed only when its content differs from what is already
  there, so an unchanged update does not rerun CI.
- An open pull request from the branch is updated instead of duplicated.
- When nothing is left to change, the pull request is closed and its branch
  deleted.
- `auto-merge: true` enables auto-merge on it. The repository must allow
  auto-merge, and a required status check gives it something to wait for.

With `delivery: push`, the changes are committed and pushed to the
checked-out branch. With `delivery: none`, they stay in the working tree for
later steps.

## Inputs

| Name | Default | Description |
|---|---|---|
| `update-lock` | `true` | Update `flake.lock`. |
| `inputs` | | Space-separated flake inputs to update. All of them when empty. |
| `repair-hashes` | `false` | Build the installables and repair the stale fixed-output hashes. |
| `installables` | `.#default` | Space- or newline-separated flake installables to build, to repair the hashes. |
| `path-to-flake-dir` | `.` | Directory that holds `flake.nix`. Every `.nix` file under it is searched for stale hashes. |
| `nix-options` | | Space-separated options to pass to every `nix` command. |
| `delivery` | `pull-request` | `pull-request`, `push` or `none`. |
| `commit-msg` | `chore(nix): update flake` | Subject of the commit. |
| `skip-ci` | `false` | Add `[skip ci]` to the commit subject. Do not use it with a pull request whose checks are required: they would never run. |
| `git-author-name` | `github-actions[bot]` | Author name of the commit. |
| `git-author-email` | `41898283+github-actions[bot]@users.noreply.github.com` | Author email of the commit. |
| `git-committer-name` | the author name | Committer name of the commit. |
| `git-committer-email` | the author email | Committer email of the commit. |
| `token` | | Token to open the pull request and push with. When empty, the pull request uses `GITHUB_TOKEN` and a push uses the credentials `actions/checkout` set. |
| `base` | the checked-out branch | Base branch of the pull request. |
| `branch` | `nix-flake-update` | Branch the pull request is pushed from. |
| `pr-title` | the commit subject | Title of the pull request. |
| `pr-body` | a summary of the updated inputs | Body of the pull request. `{{ env.GIT_COMMIT_MESSAGE }}` in it is replaced with that summary. |
| `pr-labels` | | Comma- or newline-separated labels. They must exist. |
| `pr-assignees` | | Comma- or newline-separated GitHub usernames. |
| `pr-reviewers` | | Comma- or newline-separated GitHub usernames. |
| `auto-merge` | `false` | Enable auto-merge on the pull request. |
| `merge-method` | `squash` | `squash`, `merge` or `rebase`, for auto-merge. |

Nix must already be installed. The action also uses `jq` and `gh`, which
GitHub-hosted runners already have.

## Outputs

| Name | Description |
|---|---|
| `updated` | `true` when anything changed, otherwise `false`. |
| `files` | Space-separated paths of the changed files, relative to `path-to-flake-dir`. |
| `pull-request-number` | Number of the pull request that was created, updated or closed. |
| `pull-request-url` | URL of that pull request. |
| `pull-request-operation` | `created`, `updated`, `closed` when nothing was left to change, or `none` when the branch already held the change. |

## Migrating from update-flake-lock

Change the `uses:` line, and add `permissions: pull-requests: write` if the
job does not have it. The inputs keep their names, and `pull-request-number`,
`pull-request-url` and `pull-request-operation` are the same outputs. What
differs:

- The default branch is `nix-flake-update`, not `update_flake_lock_action`.
  Set `branch` to keep the old one.
- Commits are signed by no key: `sign-commits` and the `gpg-*` inputs do not
  exist. A commit made with a GitHub App token is not marked verified either.
- `push-to-fork` does not exist.
- `pr-body` is not a Handlebars template. Only `{{ env.GIT_COMMIT_MESSAGE }}`
  is replaced, with the summary of the updated inputs.
- The default commit message and pull request title are
  `chore(nix): update flake`.

## Development

The dev shell carries the tools CI uses. Enter it with `nix develop`, or open
the repository in its devcontainer, which installs Nix.

`tests/test.sh` runs the scripts against throwaway git repositories with a
local remote, and a fake `gh`:

```sh
nix develop --command tests/test.sh                            # every test
nix develop --command tests/test.sh test_updates_a_stale_hash  # one test
nix develop --command shellcheck repair-hashes.sh update-lock.sh deliver.sh tests/test.sh
nix develop --command actionlint
```

Releases are cut by release-please from Conventional Commits. Each release
also moves the major version tag, such as `v1`, that callers pin.

## License

[MIT](LICENSE)

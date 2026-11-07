# nix-flake-update

[![CI](https://github.com/nixos-contrib/nix-flake-update/actions/workflows/ci.yml/badge.svg)](https://github.com/nixos-contrib/nix-flake-update/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A GitHub Action that repairs the fixed-output hashes a dependency bump leaves
stale: `vendorHash`, `cargoHash`, `npmDepsHash`, or any other.

A Nix package built with `buildGoModule`, `buildRustPackage` or
`buildNpmPackage` pins its fetched dependencies by hash. When Dependabot bumps
`go.sum`, `Cargo.lock` or `package-lock.json`, it does not update that hash,
so `nix build` fails with a hash mismatch until someone pastes in the new one.
This action does that on the pull request instead.

## How it works

1. Builds the flake installables. If the build succeeds, there is nothing to do.
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
4. Commits the updated files and pushes them to the checked-out branch.

The hash is found by value, not by attribute name, so it needs no
configuration per repository. Anything else that breaks the build fails the
run, as does a hash it cannot place:

- one that is computed, rather than written out as a string;
- one shared by several derivations, such as a single `lib.fakeHash`
  placeholder: give each its own;
- one that belongs to another flake input.

## Usage

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
```

For Rust, trigger on `paths: [Cargo.lock]`; for npm, on `paths: [package-lock.json]`.

Three things the workflow depends on:

- **A token that triggers workflows.** A push made with `GITHUB_TOKEN` starts
  no workflow runs, so CI would not rerun on the fixed commit. Use a GitHub App
  token, as above, or a personal access token.
- **Dependabot secrets.** Workflows Dependabot triggers cannot read Actions
  secrets. Store `APP_CLIENT_ID` and `APP_PRIVATE_KEY` as Dependabot secrets,
  at the organization or repository level.
- **The branch, not the merge commit.** `actions/checkout` checks out the
  pull request's merge commit by default, a detached `HEAD` with nowhere to
  push. Pass `ref: ${{ github.head_ref }}`.

Pair it with a ruleset that requires the build check on the default branch,
so a pull request whose hash could not be repaired waits instead of merging.

## Inputs

| Name | Default | Description |
|---|---|---|
| `installables` | `.#default` | Space- or newline-separated flake installables to build. |
| `working-directory` | `.` | Directory to build from. Every `.nix` file under it is searched for the stale hashes. |
| `commit` | `true` | Commit the updated files and push them to the checked-out branch. Set to `false` to only update the working tree. |
| `commit-message` | `chore(nix): update dependency hash` | Message of the commit. |
| `author-name` | `github-actions[bot]` | Author and committer name of the commit. |
| `author-email` | `41898283+github-actions[bot]@users.noreply.github.com` | Author and committer email of the commit. |

Nix must already be installed. The action also uses `jq`, which GitHub-hosted
runners already have.

## Outputs

| Name | Description |
|---|---|
| `updated` | `true` when at least one hash was updated, otherwise `false`. |
| `files` | Space-separated paths of the updated files, relative to `working-directory`. |

## Development

The dev shell carries the tools CI uses. Enter it with `nix develop`, or open
the repository in its devcontainer, which installs Nix.

`tests/test.sh` runs the script against throwaway copies of
`tests/fixture`, each a git repository with a local remote:

```sh
nix develop --command tests/test.sh                            # every test
nix develop --command tests/test.sh test_updates_a_stale_hash  # one test
nix develop --command shellcheck repair-hashes.sh tests/test.sh
nix develop --command actionlint
```

Releases are cut by release-please from Conventional Commits. Each release
also moves the major version tag, such as `v1`, that callers pin.

## License

[MIT](LICENSE)

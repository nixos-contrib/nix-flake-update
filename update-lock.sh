#!/usr/bin/env bash
# Updates flake.lock in the working directory, all of its inputs or only the
# ones named, and records which inputs moved, for the commit message and the
# pull request body.
#
# Kept to bash 3.2, the /bin/bash macOS runners ship.
#
# Environment:
#   INPUTS        Space-separated inputs to update. All of them when empty.
#   NIX_OPTIONS   Space-separated options to pass to nix.
#   CHANGES_FILE  Path to write the summary of the updated inputs to.

set -euo pipefail

INPUTS=${INPUTS:-}
NIX_OPTIONS=${NIX_OPTIONS:-}
CHANGES_FILE=${CHANGES_FILE:-}

# Word-split on purpose: both are whitespace-separated lists.
# shellcheck disable=SC2206
inputs=($INPUTS)
# shellcheck disable=SC2206
nix_options=($NIX_OPTIONS)

if [ ! -f flake.nix ]; then
  echo "::error::There is no flake.nix in $(pwd). Set path-to-flake-dir to the directory that holds it."
  exit 1
fi

echo "::group::nix flake update ${inputs[*]:-}"
# nix reports what it updated on stderr, so both streams are kept.
if ! log=$(nix --extra-experimental-features 'nix-command flakes' \
  ${nix_options[@]+"${nix_options[@]}"} flake update ${inputs[@]+"${inputs[@]}"} 2>&1); then
  printf '%s\n' "$log"
  echo "::endgroup::"
  echo "::error::nix flake update failed."
  exit 1
fi
printf '%s\n' "$log"
echo "::endgroup::"

# What Nix reports for each input it added, updated or removed, without its
# warnings.
changes=$(printf '%s\n' "$log" | grep -vE '^(warning|evaluation warning):' || true)

if [ -n "$CHANGES_FILE" ]; then
  printf '%s\n' "$changes" >"$CHANGES_FILE"
fi

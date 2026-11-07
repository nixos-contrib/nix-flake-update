#!/usr/bin/env bash
# Runs repair-hashes.sh against throwaway copies of tests/fixture,
# each a git repository with a local bare remote, and checks what it changed,
# committed and pushed.
#
# Usage: tests/test.sh [test_name...]

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/repair-hashes.sh
fixture=$root/tests/fixture/flake.nix

# The hashes tests/fixture/flake.nix holds, of the outputs it builds.
DEFAULT_HASH=sha256-AWZuwGBGbBS5+gbGE/usRJFj8qIBdVj+FlJiCat4xrA=
SECOND_HASH=sha256-SAwjNrQQ8a1fi/GyiURJAlWAS2U1DFJ3h+dOvdUR46Q=

# Hashes of other content, standing in for the ones a bump leaves stale:
# lib.fakeHash and the hash of the empty string.
STALE_HASH=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
OTHER_STALE_HASH=sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=

git_as_test() {
  git -c user.name=test -c user.email=test@example.com "$@"
}

# Creates a repository holding the fixture, pushed to a bare remote on main,
# and changes into it.
setup() {
  repository=$scratch/$1
  git init --quiet --bare "$repository.git"
  git init --quiet "$repository"
  cp "$fixture" "$repository/flake.nix"
  cd "$repository"
  git checkout --quiet -b main
  git add flake.nix
  git_as_test commit --quiet --message fixture
  git remote add origin "$repository.git"
  git push --quiet --set-upstream origin main
}

# Replaces a literal string in flake.nix and pushes it, as a dependency bump
# would push the change that leaves a hash stale.
change() {
  OLD=$1 NEW=$2 perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' flake.nix
  git_as_test commit --quiet --all --message change
  git push --quiet
}

# Runs the script with the given VAR=value settings, recording its exit
# status in $status and its log in $log.
run() {
  log=$scratch/$name.log
  output=$scratch/$name.output
  : >"$output"
  set +e
  env GITHUB_OUTPUT="$output" "$@" "$script" >"$log" 2>&1
  status=$?
  set -e
}

output_of() {
  sed -n "s/^$1=//p" "$output"
}

remote_subject() {
  git --git-dir="$repository.git" log -1 --format=%s main
}

expect() {
  local description=$1
  shift
  if ! "$@"; then
    echo "  expected: $description"
    echo "  --- log ---"
    sed 's/^/  /' "$log" 2>/dev/null || true
    exit 1
  fi
}

contains() {
  grep -qF -- "$2" "$1"
}

test_updates_a_stale_hash() {
  setup "$name"
  change "$DEFAULT_HASH" "$STALE_HASH"
  run INSTALLABLES=.#default
  expect "success" test "$status" -eq 0
  expect "the current hash" contains flake.nix "$DEFAULT_HASH"
  expect "updated=true" test "$(output_of updated)" = true
  expect "files=flake.nix" test "$(output_of files)" = flake.nix
  expect "the fix pushed" test "$(remote_subject)" = "chore(nix): update dependency hash"
  expect "a clean working tree" test -z "$(git status --porcelain)"
}

test_updates_a_cached_stale_hash() {
  local current
  current=$(printf 'bumped\n' | nix hash file --sri /dev/stdin)
  setup "$name"
  # Cache the output default's hash names, then change what it holds, as a
  # bump changes go.sum: Nix reuses the cached output, and only the consumer
  # built from it fails.
  nix build --no-link .#default 2>/dev/null
  change 'defaultContent = "default";' 'defaultContent = "bumped";'
  run INSTALLABLES=.#consumer
  expect "success" test "$status" -eq 0
  expect "the bumped hash" contains flake.nix "$current"
  expect "the fix pushed" test "$(remote_subject)" = "chore(nix): update dependency hash"
}

test_leaves_current_hashes_alone() {
  setup "$name"
  run INSTALLABLES=.#default
  expect "success" test "$status" -eq 0
  expect "updated=false" test "$(output_of updated)" = false
  expect "no new commit" test "$(remote_subject)" = fixture
}

test_updates_every_stale_hash() {
  setup "$name"
  change "$DEFAULT_HASH" "$STALE_HASH"
  change "$SECOND_HASH" "$OTHER_STALE_HASH"
  run INSTALLABLES=".#default .#second"
  expect "success" test "$status" -eq 0
  expect "the current default hash" contains flake.nix "$DEFAULT_HASH"
  expect "the current second hash" contains flake.nix "$SECOND_HASH"
  expect "a single commit" test "$(git log --format=%s -2 | tr '\n' ,)" = "chore(nix): update dependency hash,change,"
}

test_keeps_the_encoding() {
  local current stale
  current=$(nix hash convert --hash-algo sha256 --to nix32 "$DEFAULT_HASH")
  stale=$(nix hash convert --hash-algo sha256 --to nix32 "$STALE_HASH")
  setup "$name"
  change "$DEFAULT_HASH" "$stale"
  run INSTALLABLES=.#default
  expect "success" test "$status" -eq 0
  expect "the current hash, in nix32" contains flake.nix "\"$current\""
}

test_only_updates_the_working_tree() {
  setup "$name"
  change "$DEFAULT_HASH" "$STALE_HASH"
  run INSTALLABLES=.#default COMMIT=false
  expect "success" test "$status" -eq 0
  expect "the current hash" contains flake.nix "$DEFAULT_HASH"
  expect "no new commit" test "$(remote_subject)" = change
}

test_uses_the_commit_settings() {
  setup "$name"
  change "$DEFAULT_HASH" "$STALE_HASH"
  run INSTALLABLES=.#default COMMIT_MESSAGE="fix: hash" AUTHOR_NAME=bot AUTHOR_EMAIL=bot@example.com
  expect "success" test "$status" -eq 0
  expect "the commit message" test "$(remote_subject)" = "fix: hash"
  expect "the author" test "$(git log -1 --format='%an <%ae>')" = "bot <bot@example.com>"
}

test_fails_on_another_error() {
  setup "$name"
  # An evaluation error: a broken builder would not do, since a fixed-output
  # path already in the store is never rebuilt.
  change 'outputHashMode = "flat";' 'outputHashMode = flat;'
  run INSTALLABLES=.#default
  expect "failure" test "$status" -ne 0
  expect "the reason" contains "$log" "other than a stale hash"
  expect "no new commit" test "$(remote_subject)" = change
}

test_fails_on_a_computed_hash() {
  setup "$name"
  # Split mid-hash, so neither its SRI nor its bare base64 form is written out.
  change "\"$DEFAULT_HASH\"" "(\"${STALE_HASH:0:27}\" + \"${STALE_HASH:27}\")"
  run INSTALLABLES=.#default
  expect "failure" test "$status" -ne 0
  expect "the reason" contains "$log" "no .nix file"
}

test_fails_on_a_shared_hash() {
  setup "$name"
  change "$DEFAULT_HASH" "$STALE_HASH"
  change "$SECOND_HASH" "$STALE_HASH"
  run INSTALLABLES=".#default .#second"
  expect "failure" test "$status" -ne 0
  expect "the reason" contains "$log" "appears 2 times"
}

test_fails_on_a_detached_head() {
  setup "$name"
  change "$DEFAULT_HASH" "$STALE_HASH"
  git checkout --quiet --detach
  run INSTALLABLES=.#default
  expect "failure" test "$status" -ne 0
  expect "the reason" contains "$log" "HEAD is detached"
}

# Each test runs in its own process, so set -e and cd stay contained.
if [ "${1:-}" = --run ]; then
  name=$2
  scratch=$3
  "$name"
  exit 0
fi

tests=("$@")
if [ ${#tests[@]} -eq 0 ]; then
  while read -r test; do
    tests+=("$test")
  done <<EOF
$(declare -F | awk '$3 ~ /^test_/ { print $3 }')
EOF
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

failed=0
for test in "${tests[@]}"; do
  if "$0" --run "$test" "$scratch"; then
    echo "ok   $test"
  else
    echo "FAIL $test"
    failed=$((failed + 1))
  fi
done

echo "${#tests[@]} tests, $failed failed"
[ "$failed" -eq 0 ]

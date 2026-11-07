#!/usr/bin/env bash
# Runs the scripts of the action against throwaway git repositories, each with
# a local bare remote, and checks what they changed, committed and pushed:
#
#   repair-hashes.sh  against copies of tests/fixture
#   update-lock.sh    against a flake whose inputs are local directories
#   deliver.sh        against a plain repository, with a fake gh on the PATH
#
# Usage: tests/test.sh [test_name...]

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$root/tests/fixture/flake.nix

# The hashes tests/fixture/flake.nix holds, of the outputs it builds.
DEFAULT_HASH=sha256-AWZuwGBGbBS5+gbGE/usRJFj8qIBdVj+FlJiCat4xrA=
SECOND_HASH=sha256-SAwjNrQQ8a1fi/GyiURJAlWAS2U1DFJ3h+dOvdUR46Q=

# Hashes of other content, standing in for the ones a bump leaves stale:
# lib.fakeHash and the hash of the empty string.
STALE_HASH=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
OTHER_STALE_HASH=sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=

PR_URL=https://github.com/test/test/pull/42
EXISTING_PR="7 https://github.com/test/test/pull/7"

git_as_test() {
  git -c user.name=test -c user.email=test@example.com "$@"
}

# Creates a bare remote and a repository on main that pushes to it, and
# changes into the repository.
init_repository() {
  repository=$scratch/$1
  git init --quiet --bare "$repository.git"
  git init --quiet "$repository"
  cd "$repository"
  git checkout --quiet -b main
}

# Commits what the repository holds and pushes it.
publish() {
  git add -A
  git_as_test commit --quiet --message fixture
  git remote add origin "$repository.git"
  git push --quiet --set-upstream origin main
}

# Creates a repository holding the hash fixture.
setup() {
  init_repository "$1"
  cp "$fixture" flake.nix
  publish
}

# Replaces a literal string in flake.nix and pushes it, as a dependency bump
# would push the change that leaves a hash stale.
change() {
  OLD=$1 NEW=$2 perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' flake.nix
  git_as_test commit --quiet --all --message change
  git push --quiet
}

# Creates a repository holding only a lock file, for the delivery tests.
setup_plain() {
  init_repository "$1"
  printf '{}\n' >flake.lock
  publish
}

# Changes the lock file, as an update would.
modify() {
  printf '{"changed":true}\n' >flake.lock
}

# Creates a repository whose flake has two inputs, each a local directory so
# that updating them needs no network, with both locked. Their paths are in
# $dep and $other.
setup_lock() {
  dep=$scratch/$1-dep
  other=$scratch/$1-other
  mkdir "$dep" "$other"
  echo one >"$dep/file"
  echo one >"$other/file"

  init_repository "$1"
  cat >flake.nix <<EOF
{
  inputs = {
    dep = {
      url = "path:$dep";
      flake = false;
    };
    other = {
      url = "path:$other";
      flake = false;
    };
  };
  outputs = { self, dep, other }: { };
}
EOF
  git add flake.nix
  nix flake lock >/dev/null 2>&1
  publish
}

# Runs a script with the given VAR=value settings, recording its exit status
# in $status and its log in $log. gh is the fake one.
run_with() {
  local script=$1
  shift
  log=$scratch/$name.log
  output=$scratch/$name.output
  : >"$output"
  set +e
  env GITHUB_OUTPUT="$output" GH_LOG="$scratch/$name.gh" PATH="$scratch/bin:$PATH" \
    "$@" "$script" >"$log" 2>&1
  status=$?
  set -e
}

run() { run_with "$root/repair-hashes.sh" "$@"; }
lock() { run_with "$root/update-lock.sh" "$@"; }
deliver() { run_with "$root/deliver.sh" "$@"; }

output_of() {
  sed -n "s/^$1=//p" "$output"
}

remote_subject() {
  git --git-dir="$repository.git" log -1 --format=%s "${1:-main}"
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

# Succeeds when a file lacks a string, or does not exist.
lacks() {
  [ ! -f "$1" ] || ! grep -qF -- "$2" "$1"
}

gh_log() {
  echo "$scratch/$name.gh"
}

# --- repair-hashes.sh

test_updates_a_stale_hash() {
  setup "$name"
  change "$DEFAULT_HASH" "$STALE_HASH"
  run INSTALLABLES=.#default
  expect "success" test "$status" -eq 0
  expect "the current hash" contains flake.nix "$DEFAULT_HASH"
  expect "updated=true" test "$(output_of updated)" = true
  expect "files=flake.nix" test "$(output_of files)" = flake.nix
  expect "only flake.nix modified" test "$(git status --porcelain)" = " M flake.nix"
  expect "no new commit" test "$(remote_subject)" = change
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
}

test_leaves_current_hashes_alone() {
  setup "$name"
  run INSTALLABLES=.#default
  expect "success" test "$status" -eq 0
  expect "updated=false" test "$(output_of updated)" = false
  expect "a clean working tree" test -z "$(git status --porcelain)"
}

test_updates_every_stale_hash() {
  setup "$name"
  change "$DEFAULT_HASH" "$STALE_HASH"
  change "$SECOND_HASH" "$OTHER_STALE_HASH"
  run INSTALLABLES=".#default .#second"
  expect "success" test "$status" -eq 0
  expect "the current default hash" contains flake.nix "$DEFAULT_HASH"
  expect "the current second hash" contains flake.nix "$SECOND_HASH"
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

test_fails_on_another_error() {
  setup "$name"
  # An evaluation error: a broken builder would not do, since a fixed-output
  # path already in the store is never rebuilt.
  change 'outputHashMode = "flat";' 'outputHashMode = flat;'
  run INSTALLABLES=.#default
  expect "failure" test "$status" -ne 0
  expect "the reason" contains "$log" "other than a stale hash"
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

# --- update-lock.sh

test_update_lock_updates_every_input() {
  setup_lock "$name"
  echo two >"$dep/file"
  echo two >"$other/file"
  lock CHANGES_FILE="$scratch/$name.changes"
  expect "success" test "$status" -eq 0
  expect "flake.lock changed" test -n "$(git status --porcelain flake.lock)"
  expect "dep in the changes" contains "$scratch/$name.changes" "Updated input 'dep'"
  expect "other in the changes" contains "$scratch/$name.changes" "Updated input 'other'"
}

test_update_lock_updates_only_the_inputs_named() {
  setup_lock "$name"
  echo two >"$dep/file"
  echo two >"$other/file"
  lock INPUTS=dep CHANGES_FILE="$scratch/$name.changes"
  expect "success" test "$status" -eq 0
  expect "dep in the changes" contains "$scratch/$name.changes" "Updated input 'dep'"
  expect "other left out" lacks "$scratch/$name.changes" "Updated input 'other'"
  # One input's hash, removed and added, and no more.
  expect "one hash moved" test "$(git diff -U0 flake.lock | grep -c '^[-+] *"narHash"')" -eq 2
}

test_update_lock_leaves_a_current_lock_alone() {
  setup_lock "$name"
  lock CHANGES_FILE="$scratch/$name.changes"
  expect "success" test "$status" -eq 0
  expect "a clean working tree" test -z "$(git status --porcelain)"
}

test_update_lock_fails_without_a_flake() {
  mkdir "$scratch/$name"
  cd "$scratch/$name"
  lock
  expect "failure" test "$status" -ne 0
  expect "the reason" contains "$log" "no flake.nix"
}

# --- deliver.sh

test_deliver_pushes_to_the_branch() {
  setup_plain "$name"
  modify
  deliver DELIVERY=push COMMIT_MESSAGE="fix: lock" AUTHOR_NAME=bot AUTHOR_EMAIL=bot@example.com
  expect "success" test "$status" -eq 0
  expect "updated=true" test "$(output_of updated)" = true
  expect "files=flake.lock" test "$(output_of files)" = flake.lock
  expect "the commit message" test "$(remote_subject)" = "fix: lock"
  expect "the author" test "$(git log -1 --format='%an <%ae>')" = "bot <bot@example.com>"
  expect "the committer" test "$(git log -1 --format='%cn <%ce>')" = "bot <bot@example.com>"
  expect "a clean working tree" test -z "$(git status --porcelain)"
}

test_deliver_uses_the_committer_settings() {
  setup_plain "$name"
  modify
  deliver DELIVERY=push AUTHOR_NAME=author AUTHOR_EMAIL=author@example.com \
    COMMITTER_NAME=committer COMMITTER_EMAIL=committer@example.com
  expect "success" test "$status" -eq 0
  expect "the author" test "$(git log -1 --format='%an <%ae>')" = "author <author@example.com>"
  expect "the committer" test "$(git log -1 --format='%cn <%ce>')" = "committer <committer@example.com>"
}

test_deliver_adds_skip_ci() {
  setup_plain "$name"
  modify
  deliver DELIVERY=push SKIP_CI=true
  expect "success" test "$status" -eq 0
  expect "the marker" test "$(remote_subject)" = "chore(nix): update flake [skip ci]"
}

test_deliver_puts_the_changes_in_the_commit() {
  setup_plain "$name"
  modify
  printf "Updated input 'nixpkgs'\n" >"$scratch/$name.changes"
  deliver DELIVERY=push CHANGES_FILE="$scratch/$name.changes"
  expect "success" test "$status" -eq 0
  expect "the changes in the body" test "$(git log -1 --format=%b)" = "Updated input 'nixpkgs'"
  expect "the changes file removed" test ! -e "$scratch/$name.changes"
}

test_deliver_leaves_the_working_tree() {
  setup_plain "$name"
  modify
  deliver DELIVERY=none
  expect "success" test "$status" -eq 0
  expect "updated=true" test "$(output_of updated)" = true
  expect "no new commit" test "$(remote_subject)" = fixture
  expect "the change kept" test "$(git status --porcelain)" = " M flake.lock"
}

test_deliver_fails_on_a_detached_head() {
  setup_plain "$name"
  modify
  git checkout --quiet --detach
  deliver DELIVERY=push
  expect "failure" test "$status" -ne 0
  expect "the reason" contains "$log" "HEAD is detached"
}

test_deliver_rejects_an_unknown_delivery() {
  setup_plain "$name"
  deliver DELIVERY=carrier-pigeon
  expect "failure" test "$status" -ne 0
  expect "the reason" contains "$log" "delivery must be"
}

test_deliver_does_nothing_without_changes() {
  setup_plain "$name"
  deliver DELIVERY=pull-request
  expect "success" test "$status" -eq 0
  expect "updated=false" test "$(output_of updated)" = false
  expect "no pull request" lacks "$(gh_log)" "pr create"
  expect "no new commit" test "$(remote_subject)" = fixture
}

test_deliver_opens_a_pull_request() {
  setup_plain "$name"
  modify
  deliver DELIVERY=pull-request BRANCH=bot PR_TITLE="chore: update" \
    PR_LABELS="dependencies, auto merge" PR_REVIEWERS=alice PR_ASSIGNEES=bob
  expect "success" test "$status" -eq 0
  expect "the commit on the branch" test "$(remote_subject bot)" = "chore(nix): update flake"
  expect "main untouched" test "$(remote_subject)" = fixture
  expect "the pull request" contains "$(gh_log)" "pr create --base main --head bot --title chore: update"
  expect "the first label" contains "$(gh_log)" "--label dependencies"
  expect "the label with a space" contains "$(gh_log)" "--label auto merge"
  expect "the reviewer" contains "$(gh_log)" "--reviewer alice"
  expect "the assignee" contains "$(gh_log)" "--assignee bob"
  expect "operation=created" test "$(output_of pull-request-operation)" = created
  expect "the number" test "$(output_of pull-request-number)" = 42
  expect "the url" test "$(output_of pull-request-url)" = "$PR_URL"
}

test_deliver_builds_the_body_from_the_changes() {
  setup_plain "$name"
  modify
  printf "Updated input 'nixpkgs'\n" >"$scratch/$name.changes"
  deliver DELIVERY=pull-request BRANCH=bot CHANGES_FILE="$scratch/$name.changes"
  expect "success" test "$status" -eq 0
  expect "the changes in the body" contains "$(gh_log).body" "Updated input 'nixpkgs'"
}

test_deliver_fills_in_a_body_template() {
  setup_plain "$name"
  modify
  printf "Updated input 'nixpkgs'\n" >"$scratch/$name.changes"
  deliver DELIVERY=pull-request BRANCH=bot CHANGES_FILE="$scratch/$name.changes" \
    PR_BODY='Changes: {{ env.GIT_COMMIT_MESSAGE }}'
  expect "success" test "$status" -eq 0
  expect "the template filled in" contains "$(gh_log).body" "Changes: Updated input 'nixpkgs'"
}

test_deliver_updates_an_existing_pull_request() {
  setup_plain "$name"
  modify
  deliver DELIVERY=pull-request BRANCH=bot FAKE_PR_LIST="$EXISTING_PR" PR_LABELS=dependencies
  expect "success" test "$status" -eq 0
  expect "the pull request edited" contains "$(gh_log)" "pr edit 7"
  expect "the label added" contains "$(gh_log)" "--add-label dependencies"
  expect "no new pull request" lacks "$(gh_log)" "pr create"
  expect "operation=updated" test "$(output_of pull-request-operation)" = updated
  expect "the number" test "$(output_of pull-request-number)" = 7
}

test_deliver_leaves_an_unchanged_branch_alone() {
  local before
  setup_plain "$name"
  modify
  deliver DELIVERY=pull-request BRANCH=bot
  expect "the first run succeeds" test "$status" -eq 0
  before=$(git --git-dir="$repository.git" rev-parse bot)

  # The same change again, as the next scheduled run makes it: a new commit
  # with the same content.
  git switch --quiet main
  modify
  deliver DELIVERY=pull-request BRANCH=bot FAKE_PR_LIST="$EXISTING_PR"
  expect "success" test "$status" -eq 0
  expect "the branch not pushed" test "$(git --git-dir="$repository.git" rev-parse bot)" = "$before"
  expect "the pull request not edited" lacks "$(gh_log)" "pr edit"
  expect "operation=none" test "$(output_of pull-request-operation)" = none
}

test_deliver_closes_the_pull_request_when_nothing_is_left() {
  setup_plain "$name"
  deliver DELIVERY=pull-request FAKE_PR_LIST="$EXISTING_PR"
  expect "success" test "$status" -eq 0
  expect "updated=false" test "$(output_of updated)" = false
  expect "the pull request closed" contains "$(gh_log)" "pr close 7 --delete-branch"
  expect "operation=closed" test "$(output_of pull-request-operation)" = closed
}

test_deliver_enables_auto_merge() {
  setup_plain "$name"
  modify
  deliver DELIVERY=pull-request BRANCH=bot AUTO_MERGE=true MERGE_METHOD=rebase
  expect "success" test "$status" -eq 0
  expect "auto-merge" contains "$(gh_log)" "pr merge --auto --rebase $PR_URL"
}

test_deliver_leaves_auto_merge_off() {
  setup_plain "$name"
  modify
  deliver DELIVERY=pull-request BRANCH=bot
  expect "success" test "$status" -eq 0
  expect "no auto-merge" lacks "$(gh_log)" "pr merge"
}

test_deliver_fails_when_the_branch_is_the_base() {
  setup_plain "$name"
  modify
  deliver DELIVERY=pull-request BRANCH=main
  expect "failure" test "$status" -ne 0
  expect "the reason" contains "$log" "is the base branch"
}

test_deliver_needs_a_base_on_a_detached_head() {
  setup_plain "$name"
  modify
  git checkout --quiet --detach
  deliver DELIVERY=pull-request BRANCH=bot
  expect "failure" test "$status" -ne 0
  expect "the reason" contains "$log" "no base branch"
}

test_deliver_uses_the_given_base_on_a_detached_head() {
  setup_plain "$name"
  modify
  git checkout --quiet --detach
  deliver DELIVERY=pull-request BRANCH=bot BASE=main
  expect "success" test "$status" -eq 0
  expect "the base" contains "$(gh_log)" "--base main"
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

# A gh that records its arguments, answers the calls deliver.sh makes, and
# keeps the body it was given.
mkdir "$scratch/bin"
cat >"$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "pr list")
    if [ -n "${FAKE_PR_LIST:-}" ]; then
      echo "$FAKE_PR_LIST"
    fi
    ;;
  "pr create" | "pr edit")
    previous=""
    for argument in "$@"; do
      if [ "$previous" = --body-file ]; then
        cp "$argument" "$GH_LOG.body"
      fi
      previous=$argument
    done
    if [ "$2" = create ]; then
      echo "https://github.com/test/test/pull/42"
    fi
    ;;
esac
exit 0
EOF
chmod +x "$scratch/bin/gh"

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

#!/usr/bin/env bash
# Delivers the changes the earlier steps left in the working tree, either as a
# pull request, as a commit pushed to the checked-out branch, or not at all.
#
# A pull request lives on one branch that every run rebuilds from the base and
# pushes only when its content differs, so the same change does not rerun CI.
# The pull request is created, updated, or closed when there is nothing left
# to change.
#
# Kept to bash 3.2, the /bin/bash macOS runners ship. Needs gh for pull
# requests, which GitHub-hosted runners carry.
#
# Environment:
#   DELIVERY         "pull-request", "push" or "none".
#   COMMIT_MESSAGE   Subject of the commit.
#   CHANGES_FILE     File holding the summary update-lock.sh wrote, if any.
#   SKIP_CI          "true" to add [skip ci] to the commit subject.
#   AUTHOR_NAME, AUTHOR_EMAIL, COMMITTER_NAME, COMMITTER_EMAIL
#                    Identity of the commit.
#   BASE             Base branch of the pull request. The checked-out branch
#                    when empty.
#   BRANCH           Branch the pull request is pushed from.
#   PR_TITLE, PR_BODY
#                    Title and body of the pull request. The body is built
#                    from the summary when empty.
#   PR_LABELS, PR_ASSIGNEES, PR_REVIEWERS
#                    Comma- or newline-separated lists.
#   AUTO_MERGE       "true" to enable auto-merge on the pull request.
#   MERGE_METHOD     "squash", "merge" or "rebase", for auto-merge.
#   TOKEN            Token to push with, when it should replace the one
#                    actions/checkout configured. gh reads GH_TOKEN.

set -euo pipefail

DELIVERY=${DELIVERY:-pull-request}
COMMIT_MESSAGE=${COMMIT_MESSAGE:-chore(nix): update flake}
CHANGES_FILE=${CHANGES_FILE:-}
SKIP_CI=${SKIP_CI:-false}
AUTHOR_NAME=${AUTHOR_NAME:-github-actions[bot]}
AUTHOR_EMAIL=${AUTHOR_EMAIL:-41898283+github-actions[bot]@users.noreply.github.com}
COMMITTER_NAME=${COMMITTER_NAME:-$AUTHOR_NAME}
COMMITTER_EMAIL=${COMMITTER_EMAIL:-$AUTHOR_EMAIL}
BASE=${BASE:-}
BRANCH=${BRANCH:-nix-flake-update}
PR_TITLE=${PR_TITLE:-$COMMIT_MESSAGE}
PR_BODY=${PR_BODY:-}
PR_LABELS=${PR_LABELS:-}
PR_ASSIGNEES=${PR_ASSIGNEES:-}
PR_REVIEWERS=${PR_REVIEWERS:-}
AUTO_MERGE=${AUTO_MERGE:-false}
MERGE_METHOD=${MERGE_METHOD:-squash}
TOKEN=${TOKEN:-}

case $DELIVERY in
  pull-request | push | none) ;;
  *)
    echo "::error::delivery must be pull-request, push or none, not $DELIVERY."
    exit 1
    ;;
esac
case $MERGE_METHOD in
  squash | merge | rebase) ;;
  *)
    echo "::error::merge-method must be squash, merge or rebase, not $MERGE_METHOD."
    exit 1
    ;;
esac

set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >>"$GITHUB_OUTPUT"
  fi
}

# Prints the comma- or newline-separated items of a list, one per line,
# trimmed and without the empty ones.
items() {
  printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
}

# A token the caller passed replaces the credentials actions/checkout left in
# the git config, so that the push is made as that token: a push made with
# GITHUB_TOKEN starts no workflow runs. Setting the header to nothing first
# drops the one checkout set.
git_auth=()
if [ -n "$TOKEN" ]; then
  server=${GITHUB_SERVER_URL:-https://github.com}
  case $(git remote get-url origin 2>/dev/null || true) in
    "$server"/*)
      header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
      git_auth=(-c "http.$server/.extraheader=" -c "http.$server/.extraheader=$header")
      ;;
  esac
fi

git_remote() {
  git ${git_auth[@]+"${git_auth[@]}"} "$@"
}

files=$(git ls-files --modified --others --exclude-standard | sort -u | tr '\n' ' ' | sed 's/ $//')

existing=""
if [ "$DELIVERY" = pull-request ]; then
  existing=$(gh pr list --head "$BRANCH" --state open --json number,url --jq '.[0] // empty | "\(.number) \(.url)"')
fi

if [ -z "$files" ]; then
  echo "Nothing to update."
  set_output updated false
  set_output files ""
  if [ -n "$existing" ]; then
    number=${existing%% *}
    gh pr close "$number" --delete-branch --comment "Everything is up to date, so this pull request is no longer needed."
    set_output pull-request-number "$number"
    set_output pull-request-url "${existing#* }"
    set_output pull-request-operation closed
  fi
  exit 0
fi

set_output updated true
set_output files "$files"

if [ "$DELIVERY" = none ]; then
  echo "Updated: $files"
  exit 0
fi

changes=""
if [ -n "$CHANGES_FILE" ] && [ -s "$CHANGES_FILE" ]; then
  changes=$(head -c 60000 "$CHANGES_FILE")
fi
# A second run in the same job must not report this run's changes.
if [ -n "$CHANGES_FILE" ]; then
  rm -f "$CHANGES_FILE"
fi

subject=$COMMIT_MESSAGE
if [ "$SKIP_CI" = true ]; then
  subject="$subject [skip ci]"
fi
message=$subject
if [ -n "$changes" ]; then
  message="$subject"$'\n\n'"$changes"
fi

commit() {
  git add -A -- .
  GIT_AUTHOR_NAME=$AUTHOR_NAME GIT_AUTHOR_EMAIL=$AUTHOR_EMAIL \
    GIT_COMMITTER_NAME=$COMMITTER_NAME GIT_COMMITTER_EMAIL=$COMMITTER_EMAIL \
    git commit --quiet --message "$message"
}

current=$(git symbolic-ref --quiet --short HEAD || true)

if [ "$DELIVERY" = push ]; then
  if [ -z "$current" ]; then
    echo "::error::HEAD is detached, so there is no branch to push to. Check out the pull request branch, e.g. actions/checkout with ref: \${{ github.head_ref }}."
    exit 1
  fi
  commit
  git_remote push --quiet origin "HEAD:refs/heads/$current"
  echo "Pushed $(git rev-parse --short HEAD) to $current."
  exit 0
fi

base=${BASE:-$current}
if [ -z "$base" ]; then
  echo "::error::HEAD is detached, so there is no base branch for the pull request. Set base."
  exit 1
fi
if [ "$base" = "$BRANCH" ]; then
  echo "::error::The pull request branch $BRANCH is the base branch. Set branch to another name."
  exit 1
fi

git switch --quiet -C "$BRANCH"
commit

# Push only when the branch would change: a new commit hash alone is no reason
# to rerun CI on a pull request that already holds this content.
pushed=true
if git_remote fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null &&
  git diff --quiet "origin/$BRANCH" HEAD; then
  pushed=false
  echo "Branch $BRANCH already holds this content."
else
  git_remote push --quiet --force origin "HEAD:refs/heads/$BRANCH"
  echo "Pushed $(git rev-parse --short HEAD) to $BRANCH."
fi

body=$PR_BODY
if [ -z "$body" ]; then
  body='Automated changes by [nix-flake-update](https://github.com/nixos-contrib/nix-flake-update).'
  if [ -n "$changes" ]; then
    body="$body"$'\n\n```\n'"$changes"$'\n```'
  fi
else
  body=${body//'{{ env.GIT_COMMIT_MESSAGE }}'/$changes}
fi
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
printf '%s\n' "$body" >"$body_file"

create_flags=()
edit_flags=()
while IFS= read -r item; do
  [ -n "$item" ] || continue
  create_flags+=(--label "$item")
  edit_flags+=(--add-label "$item")
done <<EOF
$(items "$PR_LABELS")
EOF
while IFS= read -r item; do
  [ -n "$item" ] || continue
  create_flags+=(--assignee "$item")
  edit_flags+=(--add-assignee "$item")
done <<EOF
$(items "$PR_ASSIGNEES")
EOF
while IFS= read -r item; do
  [ -n "$item" ] || continue
  create_flags+=(--reviewer "$item")
  edit_flags+=(--add-reviewer "$item")
done <<EOF
$(items "$PR_REVIEWERS")
EOF

if [ -n "$existing" ]; then
  number=${existing%% *}
  url=${existing#* }
  if [ "$pushed" = true ]; then
    gh pr edit "$number" --title "$PR_TITLE" --body-file "$body_file" ${edit_flags[@]+"${edit_flags[@]}"}
    operation=updated
  else
    operation=none
  fi
else
  url=$(gh pr create --base "$base" --head "$BRANCH" --title "$PR_TITLE" --body-file "$body_file" ${create_flags[@]+"${create_flags[@]}"})
  number=${url##*/}
  operation=created
fi
echo "Pull request $number: $operation ($url)"

if [ "$AUTO_MERGE" = true ]; then
  if ! gh pr merge --auto "--$MERGE_METHOD" "$url"; then
    echo "::warning::Could not enable auto-merge on $url. Allow auto-merge in the repository settings, and require a status check so there is something to wait for."
  fi
fi

set_output pull-request-number "$number"
set_output pull-request-url "$url"
set_output pull-request-operation "$operation"

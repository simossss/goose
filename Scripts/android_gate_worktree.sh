#!/usr/bin/env bash

require_clean_pushed_worktree() {
  local app_dir="$1"
  local gate_label="$2"

  local dirty_tracked
  local untracked
  dirty_tracked="$(git -C "$app_dir" status --short --untracked-files=no | wc -l | tr -d ' ')"
  untracked="$(git -C "$app_dir" ls-files --others --exclude-standard | wc -l | tr -d ' ')"
  if [[ "$dirty_tracked" != "0" || "$untracked" != "0" ]]; then
    echo "$gate_label requires a clean git worktree." >&2
    echo "Dirty tracked files: $dirty_tracked" >&2
    echo "Untracked non-ignored files: $untracked" >&2
    echo "Commit/stash changes first, or rerun with --allow-dirty for local debugging only." >&2
    exit 1
  fi

  local upstream_ref
  if ! upstream_ref="$(git -C "$app_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    echo "$gate_label requires the current branch to have a configured upstream." >&2
    echo "Push the branch and set upstream first, or rerun with --allow-dirty for local debugging only." >&2
    exit 1
  fi

  local head_commit
  local upstream_commit
  head_commit="$(git -C "$app_dir" rev-parse HEAD)"
  upstream_commit="$(git -C "$app_dir" rev-parse '@{u}')"
  if [[ "$head_commit" != "$upstream_commit" ]]; then
    head_commit="$(git -C "$app_dir" rev-parse --short HEAD)"
    upstream_commit="$(git -C "$app_dir" rev-parse --short '@{u}')"
    echo "$gate_label requires HEAD ($head_commit) to match upstream $upstream_ref ($upstream_commit)." >&2
    echo "Pull/rebase or push the current commit first, or rerun with --allow-dirty for local debugging only." >&2
    exit 1
  fi

  echo "upstream: $upstream_ref"
}

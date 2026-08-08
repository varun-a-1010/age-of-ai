#!/usr/bin/env bash
# Local, isolated launcher and conservative upstream-update helper.
# It never mounts the host home directory or the Docker socket.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly COMPOSE_FILE="$REPO_ROOT/compose.sandbox.yml"

cd "$REPO_ROOT"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/sandbox.sh <command> [--yes]

Commands:
  setup-fork       Create/configure your GitHub fork as origin (no local commits are pushed).
  check            Fetch upstream and show whether updates are available.
  update [--yes]   Show incoming commits; --yes updates, pushes your fork, and rebuilds.
  build            Build the isolated production image from the current checkout.
  run              Build if needed and run at http://127.0.0.1:8080.
  stop             Stop and remove the sandbox container and its Docker network.
  logs             Follow sandbox logs.
EOF
}

has_remote() {
  git remote get-url "$1" >/dev/null 2>&1
}

remote_url() {
  git remote get-url "$1" 2>/dev/null
}

github_slug() {
  local url="$1"
  url="${url%.git}"
  case "$url" in
    git@github.com:*) url="${url#git@github.com:}" ;;
    ssh://git@github.com/*) url="${url#ssh://git@github.com/}" ;;
    https://github.com/*) url="${url#https://github.com/}" ;;
    http://github.com/*) url="${url#http://github.com/}" ;;
    *) return 1 ;;
  esac
  [[ "$url" == */* && "$url" != */*/* ]] || return 1
  printf '%s\n' "$url"
}

source_remote() {
  if has_remote upstream; then
    printf 'upstream\n'
  elif has_remote origin; then
    # Before setup-fork, the checkout is a direct clone and origin is upstream.
    printf 'origin\n'
  else
    die "no Git remote is configured"
  fi
}

current_branch() {
  local branch
  branch="$(git branch --show-current)"
  [[ -n "$branch" ]] || die "detached HEAD is not supported"
  printf '%s\n' "$branch"
}

require_clean_tree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    git status --short >&2
    die "working tree is not clean; review, commit, or stash changes before updating"
  fi
}

require_fork_remotes() {
  has_remote upstream || die "missing upstream remote; run './scripts/sandbox.sh setup-fork' first"
  has_remote origin || die "missing origin remote; run './scripts/sandbox.sh setup-fork' first"

  local upstream_url origin_url
  upstream_url="$(remote_url upstream)"
  origin_url="$(remote_url origin)"
  [[ "$upstream_url" != "$origin_url" ]] || die "origin still points to upstream; run './scripts/sandbox.sh setup-fork' first"
}

compose() {
  docker compose --project-directory "$REPO_ROOT" -f "$COMPOSE_FILE" "$@"
}

setup_fork() {
  command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required for setup-fork"

  if has_remote upstream && has_remote origin && [[ "$(remote_url upstream)" != "$(remote_url origin)" ]]; then
    echo "Fork remotes are already configured:"
    echo "  upstream: $(remote_url upstream)"
    echo "  origin:   $(remote_url origin)"
    return
  fi

  local source source_url source_slug user repo existing_parent fork_url branch
  source="$(source_remote)"
  source_url="$(remote_url "$source")"
  source_slug="$(github_slug "$source_url")" || die "the $source remote is not a GitHub repository: $source_url"
  user="$(gh api user --jq '.login')"
  repo="${source_slug#*/}"
  branch="$(current_branch)"

  existing_parent="$(gh repo view "$user/$repo" --json parent --jq '.parent.nameWithOwner // ""' 2>/dev/null || true)"
  fork_url="$(gh repo view "$user/$repo" --json sshUrl --jq '.sshUrl' 2>/dev/null || true)"

  if [[ -n "$fork_url" ]]; then
    [[ "$existing_parent" == "$source_slug" ]] || die "github.com/$user/$repo exists but is not a fork of $source_slug"
    if ! has_remote upstream; then
      git remote rename origin upstream
    fi
    if has_remote origin; then
      [[ "$(remote_url origin)" == "$fork_url" ]] || die "origin exists but does not point to your fork"
    else
      git remote add origin "$fork_url"
    fi
  else
    # In the current-repository form gh handles the standard conversion: old
    # origin -> upstream, new fork -> origin. gh rejects --remote when a
    # repository argument is also supplied.
    gh repo fork --remote
  fi

  require_fork_remotes
  git fetch origin "$branch"
  git branch --set-upstream-to="origin/$branch" "$branch"

  echo "Fork configured. No local commits were pushed."
  echo "Review your current work, then publish it deliberately with: git push -u origin $branch"
}

check_updates() {
  local remote branch ahead behind
  remote="$(source_remote)"
  branch="$(current_branch)"
  git fetch --prune "$remote" "$branch"
  read -r ahead behind < <(git rev-list --left-right --count "HEAD...$remote/$branch")

  echo "Current branch: $branch"
  echo "Ahead: $ahead  Behind: $behind  Source: $remote/$branch"
  if (( behind > 0 )); then
    echo
    echo "Incoming commits:"
    git log --oneline --decorate "HEAD..$remote/$branch"
    echo
    echo "Review them, then run: ./scripts/sandbox.sh update --yes"
  fi
}

update() {
  local confirm="${1:-}"
  [[ -z "$confirm" || "$confirm" == "--yes" ]] || die "unknown update option: $confirm"

  require_clean_tree
  require_fork_remotes

  local branch base head upstream_head origin_head ahead behind
  branch="$(current_branch)"
  git fetch --prune origin "$branch"
  git fetch --prune upstream "$branch"
  head="$(git rev-parse HEAD)"
  origin_head="$(git rev-parse "origin/$branch")"
  upstream_head="$(git rev-parse "upstream/$branch")"
  base="$(git merge-base HEAD "upstream/$branch")"
  read -r ahead behind < <(git rev-list --left-right --count "HEAD...upstream/$branch")

  [[ "$head" == "$origin_head" ]] || die "origin/$branch does not match HEAD; reconcile your fork before updating"

  if [[ "$head" == "$upstream_head" ]]; then
    echo "Already up to date with upstream/$branch."
    return
  fi

  if [[ "$base" == "$upstream_head" ]]; then
    echo "Your branch is $ahead commit(s) ahead of upstream; no upstream changes need applying."
    return
  fi

  echo "Incoming commits ($behind):"
  git log --oneline --decorate "HEAD..upstream/$branch"
  if [[ "$base" != "$head" ]]; then
    echo
    echo "Fork-only commits to preserve ($ahead):"
    git log --oneline --decorate "upstream/$branch..HEAD"
  fi
  if [[ "$confirm" != "--yes" ]]; then
    echo
    echo "Nothing changed. Re-run with --yes to update, push your fork, and rebuild."
    return
  fi

  if [[ "$base" == "$head" ]]; then
    git merge --ff-only "upstream/$branch"
    git push origin "$branch"
  else
    # Fork-specific commits (including this sandbox) must move on top of new
    # upstream commits. A conflict stops here; nothing is pushed or rebuilt.
    git rebase "upstream/$branch"
    git push --force-with-lease origin "$branch"
  fi
  compose build --pull game
}

case "${1:-}" in
  setup-fork) setup_fork ;;
  check) check_updates ;;
  update) update "${2:-}" ;;
  build) compose build --pull game ;;
  run) compose up --build --remove-orphans ;;
  stop) compose down --remove-orphans ;;
  logs) compose logs --follow ;;
  -h|--help|help|'') usage ;;
  *) die "unknown command: $1 (run './scripts/sandbox.sh --help')" ;;
esac

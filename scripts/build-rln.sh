#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd cargo git

git_ref_label() {
  git describe --tags --exact-match 2>/dev/null ||
    git symbolic-ref --short -q HEAD ||
    git rev-parse --short HEAD
}

checkout_rln_ref() {
  local ref="$1" current_rev target_rev
  current_rev="$(git rev-parse HEAD 2>/dev/null || true)"

  if target_rev="$(git rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)"; then
    if [ "$current_rev" = "$target_rev" ]; then
      return 0
    fi
  fi

  if [ -n "$(git status --porcelain)" ]; then
    echo "rgb-lightning-node checkout is on $(git_ref_label), expected $ref, and has local changes" >&2
    echo "commit/stash those changes and rerun sim-build-rln, or set RLN_GIT_REF=$(git_ref_label) if intentional" >&2
    exit 2
  fi

  echo "checking out rgb-lightning-node ref $ref"
  if git ls-remote --exit-code --heads "$RLN_GIT_URL" "$ref" >/dev/null 2>&1; then
    git fetch "$RLN_GIT_URL" "refs/heads/$ref:refs/remotes/rln-configured/$ref"
    git checkout -B "$ref" "refs/remotes/rln-configured/$ref"
  elif git ls-remote --exit-code --tags "$RLN_GIT_URL" "$ref" >/dev/null 2>&1; then
    git fetch "$RLN_GIT_URL" "refs/tags/$ref:refs/tags/$ref"
    git checkout --detach "$ref"
  else
    git fetch "$RLN_GIT_URL" "$ref"
    git checkout --detach FETCH_HEAD
  fi
}

if [ ! -d "$RLN_REPO/.git" ]; then
  echo "cloning rgb-lightning-node from $RLN_GIT_URL ref=$RLN_GIT_REF into $RLN_REPO"
  mkdir -p "$(dirname "$RLN_REPO")"
  if [ -n "$RLN_GIT_REF" ]; then
    git clone --branch "$RLN_GIT_REF" "$RLN_GIT_URL" "$RLN_REPO"
  else
    git clone "$RLN_GIT_URL" "$RLN_REPO"
  fi
fi

cd "$RLN_REPO"

if [ -n "$RLN_GIT_REF" ]; then
  checkout_rln_ref "$RLN_GIT_REF"
fi

if [ ! -d rust-lightning/lightning ]; then
  echo "initializing rust-lightning submodule"
  git submodule update --init --recursive --depth 1 rust-lightning
fi

export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
export SCCACHE_DIR="${SCCACHE_DIR:-$SIM_DIR/.sccache}"

echo "building rgb-lightning-node in $RLN_REPO ref=$(git_ref_label)"
cargo build --release

echo "rgb-lightning-node ready at $RLN_REPO/target/release/rgb-lightning-node"

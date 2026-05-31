#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd cargo git

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
  current_ref="$(git branch --show-current)"
  if [ "$current_ref" != "$RLN_GIT_REF" ]; then
    if [ -n "$(git status --porcelain)" ]; then
      echo "rgb-lightning-node checkout is on $current_ref, expected $RLN_GIT_REF, and has local changes" >&2
      echo "commit/stash those changes and rerun sim-build-rln, or set RLN_GIT_REF=$current_ref if intentional" >&2
      exit 2
    fi

    echo "checking out rgb-lightning-node ref $RLN_GIT_REF"
    if git show-ref --verify --quiet "refs/heads/$RLN_GIT_REF"; then
      git checkout "$RLN_GIT_REF"
    else
      git fetch "$RLN_GIT_URL" "refs/heads/$RLN_GIT_REF:refs/remotes/rln-configured/$RLN_GIT_REF"
      git checkout -B "$RLN_GIT_REF" "refs/remotes/rln-configured/$RLN_GIT_REF"
    fi
  fi
fi

if [ ! -d rust-lightning/lightning ]; then
  echo "initializing rust-lightning submodule"
  git submodule update --init --recursive --depth 1 rust-lightning
fi

export RUSTC_WRAPPER="${RUSTC_WRAPPER:-sccache}"
export SCCACHE_DIR="${SCCACHE_DIR:-$SIM_DIR/.sccache}"

echo "building rgb-lightning-node in $RLN_REPO ref=$(git branch --show-current)"
cargo build --release

echo "rgb-lightning-node ready at $RLN_REPO/target/release/rgb-lightning-node"

#!/usr/bin/env bash
# Publish a built release to the public binary-only repos.
#
#   scripts/publish-release.sh v0.4.0
#
# 1. Downloads the tarballs the Release workflow built for that tag.
# 2. Creates the GitHub release on sprathq/sprat-releases with the tarballs,
#    their .sha256 files, install.sh and LICENSE.
# 3. Regenerates Formula/sprat.rb in sprathq/homebrew-tap and pushes it.
# Requires: gh (authenticated with push access to both repos), git.
set -euo pipefail

tag="${1:?usage: publish-release.sh vX.Y.Z}"
version="${tag#v}"
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Where the release workflow ran and left its tarballs.
build_repo="${SPRAT_BUILD_REPO:-sprathq/sprat-dev}"

run_id="$(gh run list --repo "$build_repo" --workflow release.yml --json databaseId,headBranch,conclusion \
  --jq "map(select(.headBranch == \"$tag\" and .conclusion == \"success\"))[0].databaseId")"
[[ -n "$run_id" && "$run_id" != "null" ]] || { echo "no successful Release run for $tag"; exit 1; }

gh run download "$run_id" --repo "$build_repo" -D "$work/dist"
mkdir -p "$work/assets"
find "$work/dist" -type f \( -name '*.tar.gz' -o -name '*.sha256' \) -exec cp {} "$work/assets/" \;
cp "$here/scripts/install.sh" "$here/rel/overlays/LICENSE" "$work/assets/"
ls -la "$work/assets"

notes="Sprat $version — the product manager for every Claude Code agent on your machine.

Install (no Elixir or Erlang needed):

    curl -fsSL https://sprat.dev/install.sh | sh
    # or
    brew install sprathq/tap/sprat

Targets: macOS (Apple silicon, Intel), Linux (x86_64, arm64). Each .tar.gz has a .sha256 next to it."

gh release create "$tag" --repo sprathq/sprat-releases --title "Sprat $version" --notes "$notes" "$work"/assets/*

sha() { awk '{print $1}' "$work/assets/sprat-$version-$1.tar.gz.sha256"; }
base="https://github.com/sprathq/sprat-releases/releases/download/$tag"

git clone -q "https://github.com/sprathq/homebrew-tap.git" "$work/tap"
mkdir -p "$work/tap/Formula"
cat > "$work/tap/Formula/sprat.rb" <<RUBY
class Sprat < Formula
  desc "Product manager for every Claude Code agent on your machine"
  homepage "https://sprat.dev"
  version "$version"
  license :cannot_represent

  on_macos do
    on_arm do
      url "$base/sprat-$version-macos-arm64.tar.gz"
      sha256 "$(sha macos-arm64)"
    end
    on_intel do
      url "$base/sprat-$version-macos-x86_64.tar.gz"
      sha256 "$(sha macos-x86_64)"
    end
  end

  on_linux do
    on_arm do
      url "$base/sprat-$version-linux-arm64.tar.gz"
      sha256 "$(sha linux-arm64)"
    end
    on_intel do
      url "$base/sprat-$version-linux-x86_64.tar.gz"
      sha256 "$(sha linux-x86_64)"
    end
  end

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/sprat"
  end

  def caveats
    <<~EOS
      Sprat supervises Claude Code sessions; install Claude Code first.
        sprat                 open the board
        sprat serve           run Sprat in the background
        sprat install-agent   start it at login (macOS)
    EOS
  end

  test do
    assert_match "usage: sprat", shell_output("#{bin}/sprat help 2>&1", 1)
  end
end
RUBY
cd "$work/tap"
git add Formula/sprat.rb
git -c user.name="Sprat Release" -c user.email="release@sprat.dev" commit -qm "sprat $version"
git push -q origin HEAD
echo "Published $tag."

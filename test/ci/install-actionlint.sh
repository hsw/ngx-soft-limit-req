#!/bin/bash
# install-actionlint.sh — download a pinned actionlint binary into $PWD and echo
# its absolute path so a caller can capture it (e.g. into $GITHUB_OUTPUT under a
# GHA step `id:`).
#
# Usage:
#   bash test/ci/install-actionlint.sh
#
# Writes:  ./actionlint (binary)
# Stdout:  absolute path to the installed binary
#
# Supply-chain hardening: pulls a TAGGED release tarball directly from
# rhysd/actionlint's GitHub Releases and verifies its SHA256 (a version pin
# alone is insufficient — release assets can be re-uploaded without changing the
# tag). Bump ACTIONLINT_VERSION intentionally and refresh all four hashes.

set -euo pipefail

ACTIONLINT_VERSION="1.7.7"  # pinned — bump intentionally after reviewing the upstream tag.

# Per-platform SHA256 of the upstream v1.7.7 release tarballs.
sha_linux_amd64="023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757"
sha_linux_arm64="401942f9c24ed71e4fe71b76c7d638f66d8633575c4016efd2977ce7c28317d0"
sha_darwin_amd64="28e5de5a05fc558474f638323d736d822fff183d2d492f0aecb2b73cc44584f5"
sha_darwin_arm64="2693315b9093aeacb4ebd91a993fea54fc215057bf0da2659056b4bc033873db"

arch="$(uname -m)"
case "$arch" in
    x86_64)        arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
        printf 'install-actionlint.sh: unsupported arch: %s\n' "$arch" >&2
        exit 1
        ;;
esac

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
    linux|darwin) ;;
    *)
        printf 'install-actionlint.sh: unsupported OS: %s\n' "$os" >&2
        exit 1
        ;;
esac

sha_var="sha_${os}_${arch}"
expected_sha="${!sha_var:-}"
if [ -z "$expected_sha" ]; then
    printf 'install-actionlint.sh: no SHA256 pinned for %s_%s\n' "$os" "$arch" >&2
    exit 1
fi

url="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_${os}_${arch}.tar.gz"

tmp_tar="$(mktemp -t actionlint.XXXXXX.tar.gz)"
trap 'rm -f "$tmp_tar"' EXIT

curl -fsSL -o "$tmp_tar" "$url"

# Portability: GHA Linux runners ship coreutils' `sha256sum`; macOS ships BSD
# `shasum -a 256`. Probe both (this script is invoked from local macOS dev too).
if command -v sha256sum >/dev/null 2>&1; then
    actual_sha="$(sha256sum "$tmp_tar" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    actual_sha="$(shasum -a 256 "$tmp_tar" | awk '{print $1}')"
else
    printf 'install-actionlint.sh: need sha256sum or shasum to verify download\n' >&2
    exit 1
fi
if [ "$actual_sha" != "$expected_sha" ]; then
    printf 'install-actionlint.sh: SHA256 mismatch for %s\n  expected: %s\n  actual:   %s\n' \
        "$url" "$expected_sha" "$actual_sha" >&2
    exit 1
fi

# Extract only the binary (the tarball also contains README/LICENSE).
tar -xzf "$tmp_tar" actionlint >&2

echo "$(pwd)/actionlint"

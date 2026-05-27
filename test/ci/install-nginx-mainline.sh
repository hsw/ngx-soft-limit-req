#!/bin/bash
# install-nginx-mainline.sh — bootstrap nginx.org mainline apt repo, install
# the `nginx` binary package, and fetch the matching source tarball into
# /usr/local/src/nginx-${VER}/ (plus a stable symlink /usr/local/src/nginx).
# The CI build-deb job compiles the dynamic module out-of-tree against that
# unpacked source via debian/rules.
#
# Why NOT nginx-dev: Ubuntu's nginx-dev package depends on Ubuntu's distro
# nginx (~1.24), which conflicts with nginx.org mainline (1.29+). Installing
# the source tarball directly keeps the build pinned to the exact mainline
# version the module is loaded against.
#
# Usage:
#   install-nginx-mainline.sh [<nginx_version>]
#
#   nginx_version  Optional, e.g. "1.31.1". If omitted, installs the latest
#                  mainline currently advertised by the nginx.org apt repo.
#
# Designed to run as root inside a vanilla ubuntu:{22.04,24.04,26.04} container.
# Idempotent: re-running on a host where the key/sources/package/source-tarball
# are already present is a no-op.
#
# On success, the resolved nginx version is echoed on stdout (single line) so
# the workflow can capture it without re-parsing dpkg later.

set -euo pipefail

NGINX_VERSION="${1:-}"

# Keep stdout reserved for the single resolved-version line (step 10) so a
# caller can `VER=$(install-nginx-mainline.sh)` cleanly. Save the real stdout on
# fd 3, then point fd 1 at stderr for the duration so all apt/curl/gpg progress
# noise lands on stderr instead of polluting the captured value.
exec 3>&1 1>&2

# 1. Bootstrap deps. apt-get install is a no-op if already present.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg

# 2. Fetch and install the nginx.org signing key into the trusted-keyring
#    directory (signed-by approach — keeps the key scoped to this one source
#    rather than world-trusted).
KEYRING=/usr/share/keyrings/nginx-archive-keyring.gpg
curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --dearmor --yes -o "$KEYRING"

# 3. Detect Ubuntu codename (jammy / noble / future) from /etc/os-release.
# shellcheck source=/dev/null
. /etc/os-release
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [ -z "$CODENAME" ]; then
    echo "install-nginx-mainline.sh: cannot detect Ubuntu codename from /etc/os-release" >&2
    exit 1
fi

# 4. Write the nginx.org sources list. Overwrite unconditionally.
echo "deb [signed-by=${KEYRING}] https://nginx.org/packages/mainline/ubuntu ${CODENAME} nginx" \
    > /etc/apt/sources.list.d/nginx.list

# 5. Pin nginx.org over the Ubuntu archive so `apt-get install nginx` picks the
#    mainline package, not the distro nginx (Ubuntu's nginx 1.24 would otherwise
#    win on noble/oracular because it has a higher base priority).
printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
    > /etc/apt/preferences.d/99nginx

# 6. Refresh apt metadata against the new source.
apt-get update

# 7. Install nginx from nginx.org mainline. If a version was requested, pin it
#    via apt's version spec syntax. The trailing `-*` glob matches the nginx.org
#    upstream-revision suffix (e.g. `1.31.1-1~jammy`) so callers can pass the
#    bare upstream version without knowing the per-distro revision string.
if [ -n "$NGINX_VERSION" ]; then
    apt-get install -y --no-install-recommends "nginx=${NGINX_VERSION}-*"
else
    apt-get install -y --no-install-recommends nginx
fi

# 8. Resolve the installed version from the binary itself. `nginx -v` prints to
#    stderr in the form "nginx version: nginx/1.31.1"; strip everything around
#    the version triplet.
INSTALLED_VERSION=$(/usr/sbin/nginx -v 2>&1 | sed 's|.*nginx/||' | sed 's|[[:space:]].*||')
if [ -z "$INSTALLED_VERSION" ]; then
    echo "install-nginx-mainline.sh: failed to detect installed nginx version" >&2
    exit 1
fi

# 9. Fetch and unpack the matching source tarball into /usr/local/src/. The
#    symlink /usr/local/src/nginx → /usr/local/src/nginx-${VER}/ gives
#    debian/rules a stable path (NGINX_SRC default) regardless of which mainline
#    version got installed. `ln -sfn` is idempotent.
mkdir -p /usr/local/src
curl -fsSL "https://nginx.org/download/nginx-${INSTALLED_VERSION}.tar.gz" \
    -o /tmp/nginx.tar.gz
tar -C /usr/local/src -xzf /tmp/nginx.tar.gz
ln -sfn "/usr/local/src/nginx-${INSTALLED_VERSION}" /usr/local/src/nginx
rm -f /tmp/nginx.tar.gz

# 10. Emit the resolved version for the caller to capture (on the saved stdout).
echo "$INSTALLED_VERSION" >&3

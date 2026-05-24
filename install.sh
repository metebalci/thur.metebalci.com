#!/usr/bin/env bash
# install.sh — wire up the thur apt or yum repository on this host.
#
#   curl -fsSL https://thur.metebalci.com/install.sh | sudo bash
#   curl -fsSL https://thur.metebalci.com/install.sh | sudo CHANNEL=unstable bash
#
# Detects the distro family, installs the signing key under
# /usr/share/keyrings (apt) or trusts it via gpgkey= (yum), and writes the
# matching sources.list / .repo entry. Does not install any packages; prints
# the install command at the end.

set -euo pipefail

CHANNEL="${CHANNEL:-stable}"
PKG_BASE="https://pkg.thur.metebalci.com"
PUBKEY_URL="$PKG_BASE/pubkey.asc"

case "$CHANNEL" in
  stable|unstable) ;;
  *) echo "install.sh: CHANNEL must be 'stable' or 'unstable' (got: $CHANNEL)" >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "install.sh: must run as root (pipe through sudo)." >&2
  exit 1
fi

if [ ! -r /etc/os-release ]; then
  echo "install.sh: /etc/os-release missing, cannot detect distro." >&2
  exit 1
fi
. /etc/os-release

case "$ID" in
  debian|ubuntu)
    codename="${VERSION_CODENAME:-}"
    if [ -z "$codename" ]; then
      echo "install.sh: VERSION_CODENAME not set in /etc/os-release." >&2
      exit 1
    fi
    apt-get update -qq
    apt-get install -y --no-install-recommends curl gnupg ca-certificates
    install -d -m 0755 /usr/share/keyrings
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL "$PUBKEY_URL" -o "$tmp"
    gpg --dearmor < "$tmp" > /usr/share/keyrings/thur.gpg
    chmod 0644 /usr/share/keyrings/thur.gpg
    cat > /etc/apt/sources.list.d/thur.list <<EOF
deb [signed-by=/usr/share/keyrings/thur.gpg] $PKG_BASE/deb/$CHANNEL $codename main
EOF
    apt-get update
    echo
    echo "thur $CHANNEL channel wired up for $ID $codename."
    echo "Install with:  sudo apt install thurvtl thurvsa"
    ;;

  rhel|rocky|almalinux|centos|fedora|sles|opensuse-leap)
    cat > /etc/yum.repos.d/thur.repo <<EOF
[thur]
name=thur ($CHANNEL)
baseurl=$PKG_BASE/rpm/$CHANNEL/x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$PUBKEY_URL
EOF
    if command -v dnf >/dev/null 2>&1; then
      installer=dnf
    elif command -v zypper >/dev/null 2>&1; then
      installer=zypper
    else
      installer=yum
    fi
    echo
    echo "thur $CHANNEL channel wired up for $ID."
    echo "Install with:  sudo $installer install thurvtl thurvsa"
    ;;

  *)
    echo "install.sh: unsupported distro ID '$ID'." >&2
    echo "Manual instructions: https://thur.metebalci.com" >&2
    exit 1
    ;;
esac

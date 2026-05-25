#!/usr/bin/env bash
#
# Copyright (c) 2026 Mete Balci
# SPDX-License-Identifier: Apache-2.0
#
# unpublish.sh — remove a specific version from the apt + rpm trees for
# one channel, regenerate indices, re-sign. Mirror of publish.sh's index
# regeneration; the difference is that artifacts are deleted instead of
# dropped in.
#
# Usage:
#   scripts/unpublish.sh <tree-dir> <channel> <version>
#
# <version> is the upstream version string exactly as it appears in the
# pool filenames — the part between the package name and the trailing
# '-1' packaging revision. No 'v' prefix.
#   release version:     0.1.0
#   pre-release version: 0.1.0-alpha.1, 0.1.0-rc.2, 0.1.0-dev.4
# Filenames matched:
#   thurvtl_<version>-1_amd64.deb / thurvsa_<version>-1_amd64.deb
#   thurvtl-<version>-1.x86_64.rpm / thurvsa-<version>-1.x86_64.rpm
#
# Env required (same as publish.sh):
#   GPG_FINGERPRINT       signing key fingerprint
#   GPG_PASSPHRASE        passphrase
#   SUPPORTED_CODENAMES   space-separated apt suite codenames

set -euo pipefail

TREE="${1:?tree dir required}"
CHANNEL="${2:?channel required (stable|unstable)}"
VERSION="${3:?version required (e.g. 0.1.0)}"

: "${GPG_FINGERPRINT:?must be set}"
: "${GPG_PASSPHRASE:?must be set}"
: "${SUPPORTED_CODENAMES:?must be set}"

case "$CHANNEL" in
  stable|unstable) ;;
  *) echo "channel must be 'stable' or 'unstable', got: $CHANNEL" >&2; exit 1 ;;
esac

# Catch the common git-tag copy-paste mistake. Everything else is left to
# the "no files matched" check below — typos surface there with the exact
# filenames we looked for.
case "$VERSION" in
  v*) echo "version must not have a 'v' prefix, got: $VERSION" >&2; exit 1 ;;
esac

DEB_TREE="$TREE/deb/$CHANNEL"
RPM_TREE="$TREE/rpm/$CHANNEL/x86_64"

# Refuse to run against a non-existent channel tree — otherwise we'd
# regenerate empty indices and the "Removed version" message at the
# bottom would falsely imply success.
if [ ! -d "$DEB_TREE" ] && [ ! -d "$RPM_TREE" ]; then
  echo "unpublish.sh: no tree found for channel '$CHANNEL' (looked at $DEB_TREE and $RPM_TREE)" >&2
  exit 1
fi

removed_any=0
searched=""

for pkg in thurvtl thurvsa; do
  letter="${pkg:0:1}"
  f="$DEB_TREE/pool/main/$letter/$pkg/${pkg}_${VERSION}-1_amd64.deb"
  searched="${searched}  ${f}"$'\n'
  if [ -f "$f" ]; then
    rm -f "$f"
    echo "removed: $f"
    removed_any=1
  fi
done

for pkg in thurvtl thurvsa; do
  f="$RPM_TREE/${pkg}-${VERSION}-1.x86_64.rpm"
  searched="${searched}  ${f}"$'\n'
  if [ -f "$f" ]; then
    rm -f "$f"
    echo "removed: $f"
    removed_any=1
  fi
done

if [ "$removed_any" -eq 0 ]; then
  echo "unpublish.sh: no files matched version '$VERSION' in channel '$CHANNEL'." >&2
  echo "             looked for:" >&2
  printf '%s' "$searched" >&2
  exit 1
fi

gpg_sign () {
  local out=$1 in=$2 mode=$3
  printf '%s' "$GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback \
    --passphrase-fd 0 --default-key "$GPG_FINGERPRINT" \
    "--$mode" --armor --output "$out" "$in"
}

if [ -d "$DEB_TREE" ]; then
  for codename in $SUPPORTED_CODENAMES; do
    dist_dir="$DEB_TREE/dists/$codename"
    pkg_dir="$dist_dir/main/binary-amd64"
    install -d "$pkg_dir"

    (
      cd "$DEB_TREE"
      apt-ftparchive packages pool/main \
        > "dists/$codename/main/binary-amd64/Packages"
    )
    gzip -kf "$pkg_dir/Packages"

    (
      cd "$DEB_TREE"
      apt-ftparchive \
        -o "APT::FTPArchive::Release::Origin=thur" \
        -o "APT::FTPArchive::Release::Label=thur ($CHANNEL)" \
        -o "APT::FTPArchive::Release::Suite=$codename" \
        -o "APT::FTPArchive::Release::Codename=$codename" \
        -o "APT::FTPArchive::Release::Architectures=amd64" \
        -o "APT::FTPArchive::Release::Components=main" \
        -o "APT::FTPArchive::Release::Description=thur $CHANNEL channel for $codename" \
        release "dists/$codename" \
        > "dists/$codename/Release.tmp"
      mv "dists/$codename/Release.tmp" "dists/$codename/Release"
    )

    rm -f "$dist_dir/Release.gpg" "$dist_dir/InRelease"
    gpg_sign "$dist_dir/Release.gpg" "$dist_dir/Release" detach-sign
    gpg_sign "$dist_dir/InRelease"   "$dist_dir/Release" clearsign
  done
fi

if [ -d "$RPM_TREE" ]; then
  # Full rebuild (no --update): we just deleted files, and --update's
  # contract around removed packages isn't worth depending on for a
  # workflow this rarely run.
  createrepo_c "$RPM_TREE"

  rm -f "$RPM_TREE/repodata/repomd.xml.asc"
  gpg_sign "$RPM_TREE/repodata/repomd.xml.asc" \
           "$RPM_TREE/repodata/repomd.xml" detach-sign
fi

echo "Unpublished version $VERSION from $CHANNEL:"
echo "  apt pool:  $(ls "$DEB_TREE/pool/main"/*/*/*.deb 2>/dev/null | wc -l) .deb files remaining"
echo "  rpm tree:  $(ls "$RPM_TREE"/*.rpm 2>/dev/null | wc -l) .rpm files remaining"

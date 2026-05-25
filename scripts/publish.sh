#!/usr/bin/env bash
#
# Copyright (c) 2026 Mete Balci
# SPDX-License-Identifier: Apache-2.0
#
# publish.sh — build apt + rpm trees for one channel from a directory of
# release artifacts, sign the indices, drop the public key at tree root.
#
# Usage:
#   scripts/publish.sh <tree-dir> <channel> <artifacts-dir>
#
# Env required:
#   GPG_FINGERPRINT       signing key fingerprint (40-char hex)
#   GPG_PASSPHRASE        passphrase for the signing key
#   SUPPORTED_CODENAMES   space-separated apt suite codenames
#                         (e.g. "bookworm trixie noble")
#
# Channels:
#   stable    — tagged releases without a pre-release suffix (vN.M.P).
#               Includes pre-1.0 releases; the channel guarantees build /
#               signing hygiene, not API stability.
#   unstable  — pre-release tagged versions (vN.M.P-alpha.X, -beta.X,
#               -rc.X) for testing forthcoming releases.
#
# Both channels accumulate. The shared pool retains every version ever
# published into the channel; apt picks the latest matching the operator's
# constraints, or operators pin to a specific version.
#
# Expected artifact filenames (from release/release.sh):
#   thurvtl_<ver>-1_amd64.deb
#   thurvsa_<ver>-1_amd64.deb
#   thurvtl-<ver>-1.x86_64.rpm
#   thurvsa-<ver>-1.x86_64.rpm

set -euo pipefail

TREE="${1:?tree dir required}"
CHANNEL="${2:?channel required (stable|unstable)}"
ARTIFACTS="${3:?artifacts dir required}"

: "${GPG_FINGERPRINT:?must be set}"
: "${GPG_PASSPHRASE:?must be set}"
: "${SUPPORTED_CODENAMES:?must be set}"

case "$CHANNEL" in
  stable|unstable) ;;
  *) echo "channel must be 'stable' or 'unstable', got: $CHANNEL" >&2; exit 1 ;;
esac

DEB_TREE="$TREE/deb/$CHANNEL"
RPM_TREE="$TREE/rpm/$CHANNEL/x86_64"

mkdir -p "$DEB_TREE/pool/main" "$RPM_TREE"

# ----- apt tree ------------------------------------------------------------

# Drop each .deb into pool/main/<letter>/<package>/ per Debian convention.
for deb in "$ARTIFACTS"/*.deb; do
  [ -e "$deb" ] || continue
  pkg=$(dpkg-deb -f "$deb" Package)
  letter="${pkg:0:1}"
  install -d "$DEB_TREE/pool/main/$letter/$pkg"
  cp "$deb" "$DEB_TREE/pool/main/$letter/$pkg/"
done

# Per codename: emit Packages + Packages.gz from the shared pool, then a
# Release file with checksums.
gpg_sign () {
  local out=$1 in=$2 mode=$3
  printf '%s' "$GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback \
    --passphrase-fd 0 --default-key "$GPG_FINGERPRINT" \
    "--$mode" --armor --output "$out" "$in"
}

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

  # Detached signature for old apt; inline clearsigned for modern apt.
  rm -f "$dist_dir/Release.gpg" "$dist_dir/InRelease"
  gpg_sign "$dist_dir/Release.gpg" "$dist_dir/Release" detach-sign
  gpg_sign "$dist_dir/InRelease"   "$dist_dir/Release" clearsign
done

# ----- rpm tree ------------------------------------------------------------

for rpm in "$ARTIFACTS"/*.rpm; do
  [ -e "$rpm" ] || continue
  cp "$rpm" "$RPM_TREE/"
done

# --update reuses prior metadata when possible (faster); on a fresh tree it
# just builds from scratch.
createrepo_c --update "$RPM_TREE"

rm -f "$RPM_TREE/repodata/repomd.xml.asc"
gpg_sign "$RPM_TREE/repodata/repomd.xml.asc" \
         "$RPM_TREE/repodata/repomd.xml" detach-sign

# ----- pubkey + summary ----------------------------------------------------

gpg --armor --export "$GPG_FINGERPRINT" > "$TREE/pubkey.asc"

echo "Built $CHANNEL:"
echo "  apt suites:  $SUPPORTED_CODENAMES"
echo "  apt pool:    $(ls "$DEB_TREE/pool/main"/*/*/*.deb 2>/dev/null | wc -l) .deb files"
echo "  rpm tree:    $(ls "$RPM_TREE"/*.rpm 2>/dev/null | wc -l) .rpm files"
echo "  pubkey:      $TREE/pubkey.asc"

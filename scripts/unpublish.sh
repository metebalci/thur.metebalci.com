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
# <version> is the upstream Git tag (with or without the leading 'v'):
#   release:     0.1.0
#   pre-release: 0.1.0-alpha.1, 0.1.0-rc.2, 0.1.0-dev.4
#
# Tag → ecosystem mapping (matches metebalci/thur's release.sh output):
#   .deb Version field:  0.1.0     -> 0.1.0-1
#                        0.1.0-X   -> 0.1.0~X-1     ('-' -> '~')
#   .rpm ver / rel:      0.1.0     -> ver=0.1.0, rel=1
#                        0.1.0-X   -> ver=0.1.0, rel=0.X
#
# Actual filenames are looked up via the published indices
# (Packages, repodata/*-primary.xml.gz), so the script stays correct
# even if upstream changes its filename casing or '-'/'.' substitutions.
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

# Accept the git tag with or without leading 'v'.
VERSION="${VERSION#v}"

# Translate the tag into the canonical .deb Version field and .rpm
# ver/rel pair used by metebalci/thur's release.sh.
deb_version="${VERSION/-/~}-1"
if [[ "$VERSION" == *-* ]]; then
  rpm_ver="${VERSION%%-*}"
  rpm_rel="0.${VERSION#*-}"
else
  rpm_ver="$VERSION"
  rpm_rel="1"
fi

echo "Resolving version '$VERSION' in channel '$CHANNEL':"
echo "  .deb Version: $deb_version"
echo "  .rpm ver=$rpm_ver rel=$rpm_rel"

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

# .deb: walk one codename's Packages file (the shared pool means every
# codename's Packages stanzas point at the same pool/ paths). Match by
# the canonical Debian Version, take the file from the Filename: field.
if [ -d "$DEB_TREE" ]; then
  pkgs_file=""
  for codename in $SUPPORTED_CODENAMES; do
    candidate="$DEB_TREE/dists/$codename/main/binary-amd64/Packages"
    if [ -f "$candidate" ]; then
      pkgs_file="$candidate"
      break
    fi
  done
  if [ -n "$pkgs_file" ]; then
    while IFS= read -r relpath; do
      [ -z "$relpath" ] && continue
      f="$DEB_TREE/$relpath"
      if [ -f "$f" ]; then
        rm -f "$f"
        echo "removed: $f"
        removed_any=1
      fi
    done < <(awk -v want="$deb_version" '
      /^Version: / {v=$2}
      /^Filename: / {if (v==want) print $2; v=""}
    ' "$pkgs_file")
  fi
fi

# .rpm: walk primary.xml.gz. The top-level <version> in each <package>
# stanza precedes that package's <location href=>; <rpm:entry> elements
# in provides/requires don't match the line anchors.
if [ -d "$RPM_TREE" ]; then
  primary=$(ls "$RPM_TREE"/repodata/*-primary.xml.gz 2>/dev/null | head -1)
  if [ -n "$primary" ]; then
    while IFS= read -r relpath; do
      [ -z "$relpath" ] && continue
      f="$RPM_TREE/$relpath"
      if [ -f "$f" ]; then
        rm -f "$f"
        echo "removed: $f"
        removed_any=1
      fi
    done < <(gunzip -c "$primary" | awk -v wver="$rpm_ver" -v wrel="$rpm_rel" '
      /^[[:space:]]*<version / {
        v=""; r=""
        if (match($0, /ver="[^"]*"/)) v=substr($0, RSTART+5, RLENGTH-6)
        if (match($0, /rel="[^"]*"/)) r=substr($0, RSTART+5, RLENGTH-6)
      }
      /^[[:space:]]*<location / {
        if (v==wver && r==wrel && match($0, /href="[^"]*"/)) {
          print substr($0, RSTART+6, RLENGTH-7)
        }
      }
    ')
  fi
fi

if [ "$removed_any" -eq 0 ]; then
  echo "unpublish.sh: nothing matched in channel '$CHANNEL'." >&2
  echo "             looked for:" >&2
  echo "               .deb stanzas with Version=$deb_version" >&2
  echo "               .rpm packages with ver=$rpm_ver rel=$rpm_rel" >&2
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

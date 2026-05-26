# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Source for the **landing page** + **one-shot installer** at `thur.metebalci.com`, plus the **publish pipeline** that maintains the apt/yum repository at `pkg.thur.metebalci.com`. The repo itself contains no Thur source code — that lives at `metebalci/thur`. This repo only ships artifacts produced there.

The codebase is tiny (one HTML page, one installer script, one publish script, one workflow). The complexity is in the cross-repo + cross-service plumbing.

## Two-domain split

| Domain | Backed by | Holds |
|---|---|---|
| `thur.metebalci.com` | Cloudflare Pages, auto-deployed from `main` | `index.html`, `install.sh`, `LICENSE`, `README.md` |
| `pkg.thur.metebalci.com` | Cloudflare R2 bucket `thur-pkg` | apt + rpm trees, `pubkey.asc` |

The split exists because Cloudflare Pages caps individual files at 25 MiB and `.deb`/`.rpm` artifacts are close enough to that ceiling that growth would break Pages. R2 has no per-file cap, so the package tree moved there.

**Consequence:** any change to `index.html` / `install.sh` / `LICENSE` ships via a `main` push (Pages auto-deploy). Any change to the package tree ships via the `publish` workflow writing to R2. They are independent pipelines — don't conflate them.

## Channel model

Two channels — `stable` (`vN.M.P`) and `unstable` (`vN.M.P-{alpha,beta,rc}.X`). **The tag string is the source of truth** for which channel a release lands in. The GitHub UI's "prerelease" flag is ignored. Routing is done by `notify-publish.yml` in the `metebalci/thur` repo (not here) when it fires the `repository_dispatch` into this repo.

Both channels accumulate — every published version stays in the pool so operators can pin (`apt install thurvtl=0.2.0`).

## Publish flow

`.github/workflows/publish.yml` → `scripts/publish.sh`. Triggered by:

- `workflow_dispatch` (manual, with `channel` + `tag` inputs)
- `repository_dispatch` of type `thur-artifacts-available`, payload `{channel, tag}` — fired by `metebalci/thur`'s `notify-publish.yml` on every release event there

Workflow steps:

1. Resolve inputs (handles both trigger types).
2. Configure rclone for R2 — note `R2_ENDPOINT_PREFIX: 'eu.'` routes to the EU jurisdiction endpoint, must match where the bucket lives.
3. Download release assets (`*.deb`, `*.rpm`) from `metebalci/thur` for the given tag, unless `tag == "seed"` (see below).
4. **Sync existing tree from R2 first**, then run `publish.sh` to merge new artifacts in, then sync back. This is what makes channels accumulate — skip the pre-sync and you delete history.
5. Sign indices with the GPG key.

### Unpublishing a version

`.github/workflows/unpublish.yml` → `scripts/unpublish.sh`. Triggered by `workflow_dispatch` (manual, inputs `channel` + `version`) or `repository_dispatch` of type `thur-artifacts-unpublish` (auto, fired by `metebalci/thur`'s `notify-unpublish.yml` on `release: deleted` upstream — bare tag deletion intentionally does not fire it). `version` is the upstream Git tag with or without `v` (`0.1.0`, `0.1.0-rc.2`, `0.1.0-dev.4`). The script translates the tag into the canonical .deb Version (`-` → `~`, then `-1`) and .rpm ver/rel (pre-release goes into the Release field as `0.<prerel>`), then looks up the **actual** filenames via the published `Packages` and `repodata/*-primary.xml.gz` indices — so it stays correct even if upstream's filename casing or `-`/`.` substitutions drift. Removes the matched files, regenerates apt + rpm indices, re-signs, syncs to R2 (R2 sync mirrors source state, so the deleted artifacts vanish). The "channels are append-only" property is the rule; this workflow is the explicit escape hatch — operators who pinned to the removed version will fail to install until they un-pin. Gotcha for the auto path: GitHub runs the bridge against the workflow file at the *release tag's commit*, not `main` HEAD on the upstream repo — releases cut before the bridge file existed won't auto-recall and need the manual `workflow_dispatch` here.

### `seed` tag

Passing `tag: seed` via `workflow_dispatch` skips the artifact download and produces an empty-but-signed tree. Used once at bootstrap so `install.sh` can wire up `sources.list.d` entries that point at a valid (if empty) repo before any release exists. Don't use this against an already-populated tree unless you want signed but empty indices.

## Cross-distro RPM is intentional

The rpm tree is **one flat directory per channel** (`/rpm/<channel>/x86_64/`) — no per-distro subdivision. The same `.rpm` is meant to install on RHEL 9/10, SLES 15/16, openSUSE Leap 15/16 because Thur is built with a glibc 2.31 floor and statically vendored OpenSSL. If you find yourself wanting to add per-distro RPM trees, that's a signal something upstream in `metebalci/thur`'s build went wrong — check there first.

Apt is different: each codename listed in `SUPPORTED_CODENAMES` (in `publish.yml`) gets its own `dists/<codename>/` subtree, but all share the same `pool/`. Adding a new Debian/Ubuntu codename means adding it to that env var; the `.deb` itself doesn't need rebuilding.

## Local development

There's nothing to "build". Tasks you might do:

- **Edit the landing page or installer:** edit `index.html` / `install.sh` and push to `main`; Cloudflare Pages redeploys automatically.
- **Test the installer without publishing:** `bash install.sh` in a throwaway container. Note `install.sh` requires root and hits `pkg.thur.metebalci.com` for the key — there is no local-only mode. To test against a different repo URL, set `PKG_BASE` in the script (only used in one place).
- **Test the publish script locally:** `scripts/publish.sh <tree-dir> <channel> <artifacts-dir>` with `GPG_FINGERPRINT`, `GPG_PASSPHRASE`, and `SUPPORTED_CODENAMES` set. Needs `apt-utils`, `createrepo-c`, `gnupg` installed. Use a throwaway GPG key — don't import the production private key locally.
- **Trigger a republish:** Actions tab → `publish` → `Run workflow`, pick channel + tag. Useful for backfills or after fixing a signing issue.

## Things that are not secrets but look like they should be

- The GPG signing key **fingerprint** (`E1FFA6E44D8AF56EBD17997C9B4E436AE1373A4B`) is hardcoded in `publish.yml`. It's public by definition (it's in every signed index). The private key + passphrase are the secrets.
- `SUPPORTED_CODENAMES` is hardcoded in `publish.yml`. Add new codenames here as distros release.
- `R2_BUCKET` and `R2_ENDPOINT_PREFIX` are likewise in plaintext in `publish.yml`.

## Pre-commit hook

`.githooks/pre-commit` mirrors the one in `metebalci/thur`: checks author email, runs `gitleaks protect --staged` (config in `.gitleaks.toml`), and requires a Copyright + SPDX-License-Identifier in the first 5 lines of staged `.rs`/`.sh`/`.py` files. **Not auto-installed** — after cloning, run `git config core.hooksPath .githooks` once. Bypass a single commit with `git commit --no-verify`.

## Key rotation

Outlined in `README.md` § "Required Actions secrets". Don't delete the old public key from keyservers when rotating — historical signatures must keep verifying.

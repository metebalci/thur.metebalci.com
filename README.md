# thur.metebalci.com

Source for **https://thur.metebalci.com** — the landing page and one-shot
installer for [Thur VTL and Thur VSA](https://github.com/metebalci/thur).

Two domains, two roles:

| Domain | Served by | Holds |
|---|---|---|
| `thur.metebalci.com` | Cloudflare Pages, from this repo's `main` | landing page, `install.sh`, `LICENSE`, `README` |
| `pkg.thur.metebalci.com` | Cloudflare R2 bucket `thur-pkg` | apt + rpm trees, `pubkey.asc` |

The two-domain split is forced by Cloudflare Pages' 25 MiB per-file cap —
`.deb` / `.rpm` artifacts sit close enough to that limit that any future
growth would push them over. R2 has no per-file limit and zero egress
fees, so the package tree lives there. Pages keeps doing what it's good
at: cheap CDN-fronted static landing.

Every push to `main` redeploys the Pages site. The R2 tree is updated by
the `publish` workflow defined in `.github/workflows/publish.yml`.

## Channels

Two channels, parallel trees, same URL shape:

- **stable** — tagged releases without a pre-release suffix
  (`vN.M.P`). Includes pre-1.0 releases; the channel guarantees build
  and signing hygiene, not API stability. Operators on 0.x should pin
  to specific minor versions if they can't tolerate the breaks SemVer
  reserves the right to introduce before 1.0.0.
- **unstable** — pre-release tagged versions
  (`vN.M.P-alpha.X` / `-beta.X` / `-rc.X`) for testing forthcoming
  releases.

Both channels are auto-published by the `notify-publish.yml` bridge in
`metebalci/thur` on every release event there — channel is routed off
the tag string, not the GitHub UI's prerelease flag. Both channels
accumulate: every version published stays in the pool, so operators
can pin to a specific tag (`apt install thurvtl=0.2.0` or yum
equivalent) instead of always taking the latest.

## Layout (under `pkg.thur.metebalci.com`)

```
/pubkey.asc                                signing key, public half
/deb/<channel>/dists/<codename>/main/binary-amd64/{Release,Packages,Packages.gz,InRelease}
/deb/<channel>/pool/main/t/{thurvtl,thurvsa}/*.deb
/rpm/<channel>/x86_64/{repodata,*.rpm}
```

apt suites are published for the codenames listed in `RELEASING.md` —
currently `bookworm` (Debian 12), `trixie` (Debian 13), and `noble`
(Ubuntu 24.04). The shared `pool/` is referenced by every suite —
artifacts are bit-identical across releases thanks to Thur's
glibc-floor build strategy.

The rpm tree is one flat directory per channel (`/rpm/<channel>/x86_64/`).
The same `.rpm` works on every supported distro (RHEL 9 / 10, SLES 15 /
16, openSUSE Leap 15 / 16) because the binary is built against
glibc 2.31 and statically vendored OpenSSL — there's no per-distro
divergence to encode in the URL.

## Installing thur

```bash
# stable (tagged releases without pre-release suffix)
curl -fsSL https://thur.metebalci.com/install.sh | sudo bash

# unstable (pre-release tags — alpha/beta/rc)
curl -fsSL https://thur.metebalci.com/install.sh | sudo CHANNEL=unstable bash
```

Manual equivalents are in `install.sh`. The script detects the distro
family, fetches the signing key from `pkg.thur.metebalci.com/pubkey.asc`,
and writes the right `sources.list.d` or `yum.repos.d` entry.

## Publishing

```
.github/workflows/publish.yml   — entry point
scripts/publish.sh              — builds apt + rpm trees, signs indices
```

Triggered manually via `workflow_dispatch` (inputs: channel, tag), or by
a `repository_dispatch` event of type `thur-artifacts-available` carrying
`{channel, tag}` in the payload. The workflow:

1. Downloads release assets from `metebalci/thur` for the given tag
   (`*.deb` and `*.rpm`).
2. Pulls the existing tree from R2 (so we don't lose prior stable
   releases).
3. Runs `scripts/publish.sh` to drop new artifacts into the pool /
   rpm dir, regenerate `Packages.gz` / `repomd.xml`, and sign
   `Release` / `repomd.xml` with the package signing key.
4. Syncs the result back to R2.

**Auto-publish on every release of `metebalci/thur`** is wired by a small
`notify-publish.yml` workflow in that repo. It inspects the tag string
on each `release.published` event and fires `repository_dispatch` here
with the routed channel: `vN.M.P` lands in `stable`,
`vN.M.P-anything` lands in `unstable`. The maintainer never has to
remember to flip a channel toggle — the tag is the truth.

Manual publishes via `workflow_dispatch` are also available for
republishes, backfills, or out-of-band testing.

### Unpublishing a version

```
.github/workflows/unpublish.yml — entry point (workflow_dispatch only)
scripts/unpublish.sh            — removes a version, regenerates + re-signs indices
```

Both channels are normally append-only. The `unpublish` workflow is the
escape hatch when a release needs to come back out (broken build, leaked
secret, license issue). Inputs are `channel` and `version` (e.g. `0.1.0`
or `0.1.0-rc.2` — the version exactly as it appears in pool filenames,
no `v` prefix and no `-1` packaging suffix). It removes the matching
`.deb` and `.rpm` files for both `thurvtl` and `thurvsa`, rebuilds the
apt + rpm indices from the remaining pool, re-signs, and syncs to R2.
Use sparingly — operators who pinned to the removed version will see
install failures until they un-pin.

### Required Actions secrets

The workflow needs these to be set in this repo's
**Settings → Secrets and variables → Actions**:

| Secret | What it is |
|---|---|
| `GPG_PRIVATE_KEY` | armored private signing key (`gpg --armor --export-secret-keys <fingerprint>`) — stays encrypted by the passphrase below |
| `GPG_PASSPHRASE` | passphrase for the signing key |
| `R2_ACCESS_KEY_ID` | R2 API token access key (Cloudflare dashboard → R2 → Manage R2 API tokens) |
| `R2_SECRET_ACCESS_KEY` | matching secret |
| `R2_ACCOUNT_ID` | Cloudflare account ID |

The signing key fingerprint itself is **not** a secret — it's hardcoded
in `publish.yml` and republished in `RELEASING.md`. Rotation procedure:
generate a new key, update the fingerprint in `publish.yml` and
`RELEASING.md`, publish the new `pubkey.asc` via the next workflow run,
leave the old public key on the keyserver so historical signatures
keep verifying.

## License

[Apache License 2.0](LICENSE), matching the source project.

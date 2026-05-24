# thur.metebalci.com

Static site backing **https://thur.metebalci.com**, the package repository
for [Thur VTL and Thur VSA](https://github.com/metebalci/thur).

Served by Cloudflare Pages directly from this repo's `main` branch — every
push redeploys the site. The custom domain `thur.metebalci.com` is wired
in the Cloudflare Pages dashboard; no `CNAME` file in the repo (that's a
GitHub Pages convention, not a Cloudflare one).

## Layout

```
/                          landing page (index.html)
/pubkey.asc                GPG public key used to sign all indices and packages
/install.sh                one-shot installer that detects the OS and wires up apt or yum
/deb/                      Debian/Ubuntu repository (.deb)
  dists/<codename>/        one suite per supported codename
                           (bookworm, bullseye, trixie, noble, jammy, focal)
  pool/main/t/<package>/   shared .deb pool, referenced by every codename suite
/rpm/                      RHEL/Rocky/Fedora repository (.rpm)
  el<n>/<arch>/            per-distro-major, per-arch trees
  fedora<n>/<arch>/
```

The `.deb` files under `pool/` are byte-identical across codename suites —
Thur builds with a glibc-floor strategy that produces one binary per arch
that runs on every supported release. Codename suites exist so operators
can pin per-release (e.g. "tested on bookworm") and so we have headroom
to diverge later without changing the URL surface.

## Installing thur

Once the repo is populated:

```bash
# Debian / Ubuntu
curl -fsSL https://thur.metebalci.com/pubkey.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/thur.gpg
echo "deb [signed-by=/usr/share/keyrings/thur.gpg] https://thur.metebalci.com/deb $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/thur.list
sudo apt update && sudo apt install thurvtl thurvsa

# RHEL / Rocky / Fedora
sudo tee /etc/yum.repos.d/thur.repo <<'EOF'
[thur]
name=thur
baseurl=https://thur.metebalci.com/rpm/el$releasever/$basearch
gpgcheck=1
gpgkey=https://thur.metebalci.com/pubkey.asc
enabled=1
EOF
sudo dnf install thurvtl thurvsa
```

Or, as a single line on either family:

```bash
curl -fsSL https://thur.metebalci.com/install.sh | sudo bash
```

## How packages get here

The `.deb` and `.rpm` artifacts are produced by the release workflow in
[metebalci/thur](https://github.com/metebalci/thur) and published as
GitHub Release assets. A workflow in this repo picks those up on
release-published events, regenerates the apt and yum index files,
signs them with the key stored in this repo's Actions secrets, and
commits the result. Pushing to `main` triggers the Cloudflare Pages
deploy.

The signing **private** key is never in this repo. Only `pubkey.asc`
(the public half) is committed.

## License

[Apache License 2.0](LICENSE), matching the source project.

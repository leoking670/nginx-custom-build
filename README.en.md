# nginx-custom-build

Build and publish a self-compiled Nginx (with OpenSSL LTS, Brotli, and Zstd) from GitHub Actions as a signed release, and keep a single VPS auto-updated from that release.

[繁體中文 (zh-TW)](README.zh-TW.md)

---

## What this does

A daily cron job on your VPS used to compile Nginx from source. This project keeps the same idea but **moves the build to GitHub Actions** while the VPS only **pulls a signed release** and swaps the binary in place.

- **Build** — runs daily (or on demand) in a `debian:13` container that matches your VPS, so the binary is portable.
- **Sign** — the tarball is GPG-signed and published as a GitHub Release.
- **Deploy** — a single idempotent script on the VPS verifies the signature, then performs a smooth upgrade (or a first install).

## Design goals

- **Simple, not over-engineered.** One repository, one public GitHub Release, one VPS.
- **Sensible security.** Signature verification is a hard gate: the VPS never touches the running Nginx unless the artifact is verified, its dependencies resolve, and the new binary passes `nginx -t`.
- **Robust, self-healing.** State is driven by a version marker file; the script converges toward "the running version equals the latest release" and survives interrupted runs, migration from an existing Nginx build, and failed upgrades (rollback + circuit breaker).
- **Lean.** No `.deb` packaging, no cross-arch matrix, no self-hosted runner.

## How it works

```
GitHub Actions (schedule + workflow_dispatch)
  check   → compare upstream nginx stable + OpenSSL LTS against published versions
  build   → compile in debian:13 container (nginx + static OpenSSL + static zstd/brotli)
  release → sign + publish GitHub Release (tag = version)

VPS (cron, runs deploy.sh)
  fetch latest Release tag  → compare to marker (.current_version)
  download + gpgv verify    → ldd check → smooth upgrade (USR2/QUIT) or first install
```

## Versions & dependencies

- **Upgrade triggers:** Nginx `stable` and OpenSSL `LTS` only.
- **Static (bundled into the binary):** OpenSSL, Zstd, Brotli.
- **System packages (apt, minor version drift tolerated):** `pcre2`, `zlib`, `jemalloc`.
- Zstd / Brotli follow the release train: they are re-pulled on each build and do **not** themselves trigger an update.

## Repository layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/build.yml` | `check → build → release` pipeline |
| `scripts/check-update.sh` | Detect whether the upstream latest is newer than the published version |
| `versions.json` | Records the last **published** version (advanced when a build is published) |
| `deploy.sh` | The VPS-side deploy script (idempotent) |

## Setup

**One-time, GitHub side:**

1. Push this repo as a **public** repository (public releases allow the VPS to download without a token).
2. Generate a signing GPG keypair (no passphrase — the private key lives only in the repo secret):
   ```bash
   gpg --generate-key
   gpg --export-secret-keys > key.asc
   base64 key.asc | gh secret set NGINX_GPG_PRIVATE
   gpg --export > nginx-signer.asc   # this is the public key
   ```
3. Trigger a build (wait for the schedule, or run the workflow manually). The first run publishes a Release tagged `nginx-<v>-openssl-<v>`.

**One-time, VPS side (as root):**

1. Install the public key into a keyring:
   ```bash
   gpg --no-default-keyring --keyring /usr/share/keyrings/nginx-signer.gpg --import nginx-signer.asc
   ```
2. Copy `deploy.sh` to your VPS and set `REPO="OWNER/REPO"` at the top.
3. Add a cron entry (VPS local time):
   ```cron
   0 4 * * * /usr/local/sbin/nginx-update/deploy.sh
   ```
4. Run it once by hand. On a fresh VPS it performs a first install (generating a minimal placeholder `nginx.conf`); on a machine that already runs an existing Nginx build it upgrades smoothly in place and records a marker.

## Conventions & limits

- `nginx.conf` is **not** "owned": on a fresh install the script writes a minimal placeholder, and it **never** overwrites an existing configuration.
- Release tag is the single source of truth for the installed version; `versions.json` is only for CI's "do we need to build?" decision.
- A failed `gpgv` verification, a missing dependency (`ldd`), or a failed `nginx -t` trips the circuit breaker — the running Nginx is left untouched.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

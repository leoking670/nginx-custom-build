# nginx-custom-build

Build and publish a self-compiled Nginx (with OpenSSL LTS, Brotli, and Zstd) from GitHub Actions as a signed release, and keep a single host auto-updated from that release.

[繁體中文 (zh-TW)](README.zh-TW.md)

---

## What this does

A daily cron job on your host used to compile Nginx from source. This project keeps the same idea but **moves the build to GitHub Actions** while the host only **pulls a signed release** and swaps the binary in place.

- **Build** — runs daily (or on demand) in a `debian:13` container that matches your host, so the binary is portable.
- **Sign** — the tarball is GPG-signed and published as a GitHub Release.
- **Deploy** — a single idempotent script on the host verifies the signature, then performs a smooth upgrade (or a first install).

## How it works

```
GitHub Actions (schedule + workflow_dispatch)
  check   → compare upstream nginx stable + OpenSSL LTS against published versions
  build   → compile in debian:13 container (nginx + static OpenSSL + static zstd/brotli)
  release → sign + publish GitHub Release (tag = version)

Host (cron, runs deploy.sh)
  fetch latest Release tag  → compare to marker (.current_version)
  download + gpgv verify    → ldd check → smooth upgrade (USR2/QUIT) or first install
```

## Versions & dependencies

- **Upgrade triggers:** Nginx `stable` and OpenSSL `LTS` only.
- **Static (bundled into the binary):** OpenSSL, Zstd, Brotli.
- **System packages (APT):** `pcre2`, `zlib`, `jemalloc`.
- Zstd / Brotli follow the release train: they are re-pulled on each build and do **not** themselves trigger an update.

## Repository layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/build.yml` | `check → build → release` pipeline |
| `scripts/check-update.sh` | Detect whether the upstream latest is newer than the published version |
| `versions.json` | Records the last **published** version (advanced when a build is published) |
| `deploy.sh` | The host-side deploy script |

## Setup

**One-time, GitHub side:**

1. Push this repo as a **public** repository — public releases let the host download without a token.
2. Generate a signing GPG keypair:
   ```bash
   gpg --generate-key
   gpg --export-secret-keys --armor > key.asc
   gh secret set NGINX_GPG_PRIVATE < key.asc
   gpg --export > nginx-signer.asc
   ```
3. Trigger a build (wait for the schedule, or run the workflow manually). The first run publishes a Release tagged `nginx-<v>-openssl-<v>`.

**One-time, host side (as root):**

1. Install the public key into a keyring:
   ```bash
   gpg --no-default-keyring --keyring /usr/share/keyrings/nginx-signer.gpg --import nginx-signer.asc
   ```
2. Install `deploy.sh` to your host (must be executable, see the exec-bit note below) and set `REPO="OWNER/REPO"` at the top:
   ```bash
   install -d -m 0755 /usr/local/sbin/nginx-update
   install -m 0755 deploy.sh /usr/local/sbin/nginx-update/deploy.sh
   ```
3. Add a cron entry (host local time):
   ```cron
   0 4 * * * /usr/local/sbin/nginx-update/deploy.sh
   ```
4. Run it once by hand. On a fresh host it performs a first install (generating a minimal placeholder `nginx.conf`); on a machine that already runs an existing Nginx build it upgrades smoothly in place and records a marker.

## Conventions & limits

- On a fresh install the script writes only a minimal placeholder `nginx.conf`. It does **not** overwrite an existing configuration.
- Release tag is the single source of truth for the installed version; `versions.json` is only for CI's "do we need to build?" decision.
- A failed `gpgv` verification, a missing dependency (`ldd`), or a failed `nginx -t` trips the circuit breaker — the running Nginx is left untouched.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

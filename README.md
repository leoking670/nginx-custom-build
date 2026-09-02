# nginx-custom-build

Build and publish a self-compiled Nginx (with OpenSSL LTS, Brotli, and Zstd) from GitHub Actions as a signed release, and keep a single VPS auto-updated from that release.

> English (en) · [繁體中文 (zh-TW)](README.md)

---

## English

### What this does

A daily cron job on your VPS used to compile Nginx from source. This project keeps the same idea but **moves the build to GitHub Actions** while the VPS only **pulls a signed release** and swaps the binary in place.

- **Build** — runs daily (or on demand) in a `debian:13` container that matches your VPS, so the binary is portable.
- **Sign** — the tarball is GPG-signed and published as a GitHub Release.
- **Deploy** — a single idempotent script on the VPS verifies the signature, then performs a smooth upgrade (or a first install).

### Design goals

- **Simple, not over-engineered.** One repository, one public GitHub Release, one VPS.
- **Sensible security.** Signature verification is a hard gate: the VPS never touches the running Nginx unless the artifact is verified, its dependencies resolve, and the new binary passes `nginx -t`.
- **Robust, self-healing.** State is driven by a version marker file; the script converges toward "the running version equals the latest release" and survives interrupted runs, migration from a legacy install, and failed upgrades (rollback + circuit breaker).
- **Lean.** No `.deb` packaging, no cross-arch matrix, no self-hosted runner.

### How it works

```
GitHub Actions (schedule + workflow_dispatch)
  check   → compare upstream nginx stable + OpenSSL LTS against released versions
  build   → compile in debian:13 container (nginx + static OpenSSL + static zstd/brotli)
  release → sign + publish GitHub Release (tag = version)

VPS (cron, runs deploy.sh)
  fetch latest Release tag  → compare to marker (.current_version)
  download + gpgv verify    → ldd check → smooth upgrade (USR2/QUIT) or first install
```

### Versions & dependencies

- **Upgrade triggers:** Nginx `stable` and OpenSSL `LTS` only.
- **Static (bundled into the binary):** OpenSSL, Zstd, Brotli.
- **System packages (apt, minor version drift tolerated):** `pcre2`, `zlib`, `jemalloc`.
- Zstd / Brotli follow the release train: they are re-pulled on each build and do **not** themselves trigger an update.

### Repository layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/build.yml` | `check → build → release` pipeline |
| `scripts/check-update.sh` | Detect whether the upstream latest is newer than the released version |
| `versions.json` | Records the last **published** version (advanced on successful release only) |
| `deploy.sh` | The VPS-side deploy script (idempotent) |

### Setup

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
4. Run it once by hand. On a fresh VPS it performs a first install (generating a minimal placeholder `nginx.conf`); on a machine that already runs a legacy Nginx build it upgrades smoothly in place and records a marker.

### Conventions & limits

- `nginx.conf` is **not** "owned": on a fresh install the script writes a minimal placeholder, and it **never** overwrites an existing configuration.
- Release tag is the single source of truth for the installed version; `versions.json` is only for CI's "do we need to build?" decision.
- A failed `gpgv` verification, a missing dependency (`ldd`), or a failed `nginx -t` trips the circuit breaker — the running Nginx is left untouched.

### License

GPL-3.0-or-later. See [LICENSE](LICENSE).

---

## 繁體中文 (zh-TW)

### 這是做什麼的

以往你的 VPS 每天定時從原始碼自行編譯 Nginx。這個專案沿用相同想法,但**把建置搬到 GitHub Actions**,VPS 只負責**拉取已簽署的 Release**,並就地換上新的二進位檔。

- **建置** — 每天(或手動觸發)在與 VPS 一致的 `debian:13` 容器內執行,確保二進位檔可攜。
- **簽署** — tarball 以 GPG 簽署,並以 GitHub Release 發佈。
- **部署** — 單一冪等腳本在 VPS 上驗證簽名,執行平滑升級(或首次安裝)。

### 設計目標

- **簡潔,不過度設計。** 一個倉庫、一個公開 Release、一台 VPS。
- **合理的安全性。** 簽名驗證是硬性門檻:除非產物通過驗證、相依性解析成功、且新二進位檔通過 `nginx -t`,否則 VPS 不會碰正在執行的 Nginx。
- **穩健、可自癒。** 狀態由版本標記檔驅動;腳本收斂到「執行中版本 == 最新 Release」,可承受中斷重跑、自舊版安裝遷移、以及升級失敗(回滾 + 熔斷)。
- **精簡。** 沒有 `.deb` 打包、沒有跨架構矩陣、沒有自架 runner。

### 運作方式

```
GitHub Actions (schedule + workflow_dispatch)
  check   → 比較上游 nginx stable + OpenSSL LTS 與已發佈版本
  build   → 在 debian:13 容器內編譯(nginx + 靜態 OpenSSL + 靜態 zstd/brotli)
  release → 簽署並發佈 GitHub Release(tag = 版本號)

VPS(cron 執行 deploy.sh)
  取最新 Release tag → 與標記檔 (.current_version) 比對
  下載 + gpgv 驗證 → ldd 檢查 → 平滑升級 (USR2/QUIT) 或首次安裝
```

### 版本與相依性

- **升級觸發條件:** 僅 Nginx `stable` 與 OpenSSL `LTS`。
- **靜態(編入二進位檔):** OpenSSL、Zstd、Brotli。
- **系統套件(apt,容忍小版本漂移):** `pcre2`、`zlib`、`jemalloc`。
- Zstd / Brotli 隨版本列車更新:每次建置時重新抓取,本身**不**觸發更新。

### 倉庫結構

| 路徑 | 用途 |
| --- | --- |
| `.github/workflows/build.yml` | `check → build → release` 管線 |
| `scripts/check-update.sh` | 偵測上游最新版是否比已發佈版新 |
| `versions.json` | 記錄最後一次**已發佈**的版本(僅在 Release 成功後更新) |
| `deploy.sh` | VPS 端的部署腳本(冪等) |

### 設定

**一次性,GitHub 端:**

1. 將此倉庫推為**公開**(public)倉庫——公開 Release 可讓 VPS 免 token 下載。
2. 產生簽署用的 GPG 金鑰對(無密碼——私鑰僅存於 repo secret):
   ```bash
   gpg --generate-key
   gpg --export-secret-keys > key.asc
   base64 key.asc | gh secret set NGINX_GPG_PRIVATE
   gpg --export > nginx-signer.asc   # 這是公鑰
   ```
3. 觸發建置(等待排程,或手動執行 workflow)。首次執行會發佈一個 tag 為 `nginx-<v>-openssl-<v>` 的 Release。

**一次性,VPS 端(以 root):**

1. 將公鑰匯入 keyring:
   ```bash
   gpg --no-default-keyring --keyring /usr/share/keyrings/nginx-signer.gpg --import nginx-signer.asc
   ```
2. 將 `deploy.sh` 複製到 VPS,並在頂端設定 `REPO="OWNER/REPO"`。
3. 加入 cron(VPS 本地時間):
   ```cron
   0 4 * * * /usr/local/sbin/nginx-update/deploy.sh
   ```
4. 手動執行一次。全新 VPS 會執行首次安裝(產生最小佔位 `nginx.conf`);已運行舊版 Nginx 的機器則就地平滑升級,並記錄標記。

### 慣例與限制

- `nginx.conf` **並非**被此專案「持有」:全新安裝時腳本只寫最小佔位設定,且**絕不**覆寫既有設定。
- Release tag 是已安裝版本的唯一真源;`versions.json` 僅供 CI 決定「是否需要建置」。
- `gpgv` 驗證失敗、相依性缺失(`ldd`)、或 `nginx -t` 失敗會觸發熔斷——正在執行的 Nginx 保持不受影響。

### 授權

GPL-3.0-or-later。詳見 [LICENSE](LICENSE)。

---

## License

This project is licensed under the GNU General Public License v3.0 (or later). See [LICENSE](LICENSE) for the full text.

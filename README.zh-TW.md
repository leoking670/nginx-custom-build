# nginx-custom-build

從 GitHub Actions 編譯並發佈一個自行編譯、已簽署的 Nginx(含 OpenSSL LTS、Brotli、Zstd)Release,讓單一主機持續自動更新。

[English (en)](README.md)

---

## 這是做什麼的

以往你的主機每天定時從原始碼自行編譯 Nginx。這個專案沿用相同想法,但**把建置搬到 GitHub Actions**,主機只負責**拉取已簽署的 Release**,並就地換上新的二進位檔。

- **建置** — 每天(或手動觸發)在與主機一致的 `debian:13` 容器內執行,確保二進位檔可攜。
- **簽署** — tarball 以 GPG 簽署,並以 GitHub Release 發佈。
- **部署** — 單一冪等腳本在主機上驗證簽名,執行平滑升級(或首次安裝)。

## 運作方式

```
GitHub Actions (schedule + workflow_dispatch)
  check   → 比較上游 nginx stable + OpenSSL LTS 與已發佈版本
  build   → 在 debian:13 容器內編譯(nginx + 靜態 OpenSSL + 靜態 zstd/brotli)
  release → 簽署並發佈 GitHub Release(tag = 版本號)

主機(cron 執行 deploy.sh)
  取最新 Release tag → 與標記檔 (.current_version) 比對
  下載 + gpgv 驗證 → ldd 檢查 → 平滑升級 (USR2/QUIT) 或首次安裝
```

## 版本與相依性

- **升級觸發條件:** 僅 Nginx `stable` 與 OpenSSL `LTS`。
- **靜態(編入二進位檔):** OpenSSL、Zstd、Brotli。
- **系統套件(APT):** `pcre2`、`zlib`、`jemalloc`。
- Zstd / Brotli 隨版本列車更新:每次建置時重新抓取,本身**不**觸發更新。

## 倉庫結構

| 路徑 | 用途 |
| --- | --- |
| `.github/workflows/build.yml` | `check → build → release` 管線 |
| `scripts/check-update.sh` | 偵測上游最新版是否比已發佈版新 |
| `versions.json` | 記錄最後一次**已發佈**的版本(在建置發佈時更新) |
| `deploy.sh` | 主機端的部署腳本 |

## 設定

隨附的 `nginx-signer.asc` 是 `leoking670/nginx-custom-build` 的簽署公鑰。若使用自己的 fork,請替換為自己的公鑰,並將對應私鑰設定為 `NGINX_GPG_PRIVATE`。

**一次性,GitHub 端:**

1. 將此倉庫推為**公開**倉庫——公開 Release 可讓主機免 token 下載。
2. 產生簽署用的 GPG 金鑰對:
   ```bash
   gpg --generate-key
   gpg --armor --export-secret-keys KEY_FINGERPRINT | gh secret set NGINX_GPG_PRIVATE
   gpg --armor --output nginx-signer.asc --export KEY_FINGERPRINT
   ```
   請使用專供 CI 簽署、且不設密碼的金鑰,不要上傳個人金鑰。工作流程以非互動方式簽署,不會處理密碼提示。
3. 觸發建置(等待排程,或手動執行 workflow)。首次執行會發佈一個 tag 為 `nginx-<v>-openssl-<v>` 的 Release。

**一次性,主機端(以 root):**

需要使用 systemd 的 Debian 13 x86_64 主機。

1. 一次性安裝相依套件,再匯入公鑰。部署時會檢查相依性並提示缺少的套件:
   ```bash
   apt-get update
   apt-get install -y ca-certificates curl jq gnupg gpgv tar util-linux libc-bin zlib1g libpcre2-8-0 libjemalloc2 cron
   install -d -m 0755 /usr/share/keyrings
   gpg --dearmor --output /usr/share/keyrings/nginx-signer.gpg nginx-signer.asc
   ```
2. 安裝 `deploy.sh`,再編輯已安裝腳本中的 `REPO="OWNER/REPO"`,指定你的 Release 倉庫:
   ```bash
   install -d -m 0755 /usr/local/sbin/nginx-update
   install -m 0755 deploy.sh /usr/local/sbin/nginx-update/deploy.sh
   ```
3. 加入 cron(主機本地時間):
   ```cron
   0 4 * * * /usr/local/sbin/nginx-update/deploy.sh
   ```
4. 手動執行一次。全新主機會執行首次安裝(產生最小佔位 `nginx.conf`);已運行既有 Nginx 的機器則就地平滑升級,並記錄標記。

## 慣例與限制

- `nginx.conf` 若為全新安裝時腳本只寫最小佔位設定。**不**覆寫既有設定。
- Release tag 是已安裝版本的唯一真源;`versions.json` 僅供 CI 決定「是否需要建置」。
- `gpgv` 驗證失敗、相依性缺失(`ldd`)、或 `nginx -t` 失敗會觸發熔斷——正在執行的 Nginx 保持不受影響。
- 平滑升級失敗會嘗試恢復舊二進位檔並重新啟動服務,然後觸發熔斷。排除故障後,刪除 `/var/lib/nginx-update-breaker` 再重試。
- 已有安裝若缺少 `.current_version`,需確認設定有效且服務正在執行。安裝中斷需人工恢復;已有標記且已停服的安裝維持停服。

## 授權

GPL-3.0-or-later。詳見 [LICENSE](LICENSE)。

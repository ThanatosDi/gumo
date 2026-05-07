# gumo

容器化的 MongoDB 備份還原工具。內建 [`gum`](https://github.com/charmbracelet/gum) 提供互動式 TUI，並同時支援無人值守（unattended）模式。

底層呼叫 `mongorestore`（mongodb-database-tools 100.x），自動偵測 `mongodump` 產生的 `*.gz` 壓縮檔。

## 功能

- **互動式還原** — 列出 `/backup` 下所有備份資料夾，選擇要還原的備份與資料庫，互動式輸入連線資訊。
- **無人值守還原** — 透過環境變數驅動，可放進 cron / CI / Kubernetes Job。
- **多資料庫選擇** — 支援多選、「全部」、以及特別處理 `admin` 資料庫（預設跳過）。
- **可選 drop** — 可選擇匯入前先 drop 既有 collections。
- **自動偵測壓縮** — 備份目錄內含 `*.gz` 時自動加上 `--gzip`。

## 目錄結構

```
.
├── Dockerfile                 # 多階段建置：gum builder + ubuntu runtime
├── restore.sh                 # 互動式 entrypoint
├── restore-unattended.sh      # 無人值守腳本，可直接以 entrypoint 覆寫呼叫
└── .github/workflows/
    └── docker-publish.yml     # 自動 build 並推送到 Docker Hub
```

## 使用方式

備份目錄請以 `mongodump --out /your/backup/dir` 產生，預期結構為：

```
/host/backup/
├── 2026-01-30_dump/
│   ├── admin/
│   ├── myapp/
│   └── analytics/
└── 2026-02-15_dump/
    └── myapp/
```

### 互動式（預設 entrypoint）

```bash
docker run --rm -it \
  -v /host/backup:/backup \
  thanatosdi/gumo:latest
```

如要連線到 host 上的 MongoDB（macOS/Windows 用 Docker Desktop）：

```bash
docker run --rm -it \
  -v /host/backup:/backup \
  -e MONGO_HOST=host.docker.internal \
  thanatosdi/gumo:latest
```

### 無人值守

覆寫 entrypoint 改用 `restore-unattended`：

```bash
docker run --rm \
  -v /host/backup:/backup \
  -e BACKUP_NAME=2026-01-30_dump \
  -e MONGO_HOST=mongo.internal \
  -e MONGO_PORT=27017 \
  -e MONGO_USER=admin \
  -e MONGO_PASS=secret \
  -e DATABASES=myapp,analytics \
  -e DROP_BEFORE_RESTORE=true \
  --entrypoint /usr/local/bin/restore-unattended \
  thanatosdi/gumo:latest
```

## 環境變數

| 變數 | 預設值 | 說明 |
|---|---|---|
| `BACKUP_DIR` | `/backup` | 容器內備份根目錄 |
| `BACKUP_NAME` | （必填，僅 unattended）| 要還原的備份子資料夾名稱 |
| `DATABASES` | （空，全選） | 逗號分隔；留空則自動全選（依 `INCLUDE_ADMIN` 決定是否含 admin）|
| `INCLUDE_ADMIN` | `false` | 自動全選時是否納入 `admin` |
| `DROP_BEFORE_RESTORE` | `true` | 是否在匯入前 drop 既有 collections |
| `MONGO_HOST` | `localhost` | MongoDB 主機 |
| `MONGO_PORT` | `27017` | MongoDB 連接埠 |
| `MONGO_USER` | （空，免認證） | 認證使用者名稱 |
| `MONGO_PASS` | （空） | 認證密碼，搭配 `MONGO_USER` 使用，認證資料庫固定為 `admin` |

互動式版本（`restore.sh`）會在環境變數未設定時逐一詢問。

## 從源碼建置

```bash
docker build -t gumo:local .
```

支援 `linux/amd64` 與 `linux/arm64`。多架構建置範例：

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t thanatosdi/gumo:latest \
  --push .
```

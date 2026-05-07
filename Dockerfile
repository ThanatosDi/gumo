# syntax=docker/dockerfile:1

# ============================================
# Stage 1: 建置 gum (charmbracelet/gum) 二進位
# 對應 image history 中:
#   COPY /go/bin/gum /usr/bin/gum
# ============================================
FROM golang:1.23-bookworm AS gum-builder

RUN go install github.com/charmbracelet/gum@latest

# ============================================
# Stage 2: 最終 runtime image
# 對應 image label:
#   org.opencontainers.image.ref.name=ubuntu
#   org.opencontainers.image.version=26.04
# ============================================
FROM ubuntu:latest

# 從 builder 複製 gum
COPY --from=gum-builder /go/bin/gum /usr/bin/gum

# 安裝 MongoDB apt repo 所需的工具
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates gnupg curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 加入 MongoDB 8.0 官方 apt 來源 (Ubuntu noble)
RUN curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
        gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor && \
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" \
        | tee /etc/apt/sources.list.d/mongodb-org-8.0.list

# 安裝 mongodb-database-tools (mongorestore 等)
RUN apt-get update && apt-get install -y --no-install-recommends \
        mongodb-database-tools \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 複製還原腳本
COPY restore.sh /usr/local/bin/restore.sh
COPY restore-unattended.sh /usr/local/bin/restore-unattended

RUN chmod +x /usr/local/bin/restore.sh /usr/local/bin/restore-unattended

WORKDIR /backup

ENTRYPOINT ["/usr/local/bin/restore.sh"]

#!/bin/bash
set -e

# ============================================
# MongoDB 無人值守還原腳本
# ============================================

# 預設值
BACKUP_DIR="${BACKUP_DIR:-/backup}"
BACKUP_NAME="${BACKUP_NAME:-}"
DATABASES="${DATABASES:-}"
INCLUDE_ADMIN="${INCLUDE_ADMIN:-false}"
DROP_BEFORE_RESTORE="${DROP_BEFORE_RESTORE:-true}"
MONGO_HOST="${MONGO_HOST:-localhost}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USER="${MONGO_USER:-}"
MONGO_PASS="${MONGO_PASS:-}"

# ============================================
# 日誌函數
# ============================================

log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

# ============================================
# 驗證函數
# ============================================

validate_required() {
    if [[ -z "$BACKUP_NAME" ]]; then
        log_error "必須設定 BACKUP_NAME 環境變數"
        exit 1
    fi
}

validate_backup_exists() {
    local backup_path="$BACKUP_DIR/$BACKUP_NAME"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_error "備份目錄不存在: $BACKUP_DIR"
        exit 1
    fi

    if [[ ! -d "$backup_path" ]]; then
        log_error "備份資料夾不存在: $backup_path"
        exit 1
    fi
}

# ============================================
# 主程式
# ============================================

main() {
    log_info "MongoDB 無人值守還原腳本啟動"
    log_info "================================"

    # 1. 驗證必要參數
    validate_required
    validate_backup_exists

    local backup_path="$BACKUP_DIR/$BACKUP_NAME"
    log_info "備份來源: $backup_path"
    log_info "目標主機: $MONGO_HOST:$MONGO_PORT"

    # 2. 掃描該備份內的資料庫
    local databases=()
    local has_admin=false

    while IFS= read -r -d '' dir; do
        local dbname
        dbname=$(basename "$dir")
        [[ "$dbname" == .* ]] && continue
        if [[ "$dbname" == "admin" ]]; then
            has_admin=true
        fi
        databases+=("$dbname")
    done < <(find "$backup_path" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    if [[ ${#databases[@]} -eq 0 ]]; then
        log_error "備份資料夾內沒有資料庫目錄: $backup_path"
        exit 1
    fi

    log_info "找到 ${#databases[@]} 個資料庫: ${databases[*]}"

    # 3. 決定要還原的資料庫
    local selected_databases=()

    if [[ -n "$DATABASES" ]]; then
        # 使用者指定了資料庫
        IFS=',' read -ra selected_databases <<< "$DATABASES"
        log_info "使用者指定還原: ${selected_databases[*]}"

        # 驗證指定的資料庫存在
        for db in "${selected_databases[@]}"; do
            local found=false
            for available_db in "${databases[@]}"; do
                if [[ "$db" == "$available_db" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == "false" ]]; then
                log_error "指定的資料庫不存在於備份中: $db"
                exit 1
            fi
        done
    else
        # 自動選擇全部（排除 admin，除非 INCLUDE_ADMIN=true）
        for db in "${databases[@]}"; do
            if [[ "$db" == "admin" ]]; then
                if [[ "$INCLUDE_ADMIN" == "true" ]]; then
                    selected_databases+=("$db")
                fi
            else
                selected_databases+=("$db")
            fi
        done
        log_info "自動選擇還原: ${selected_databases[*]}"
    fi

    if [[ ${#selected_databases[@]} -eq 0 ]]; then
        log_error "沒有資料庫可還原"
        exit 1
    fi

    # 4. 建構 mongorestore 命令
    local restore_cmd=(mongorestore)
    restore_cmd+=(--host "$MONGO_HOST")
    restore_cmd+=(--port "$MONGO_PORT")

    if [[ -n "$MONGO_USER" ]]; then
        restore_cmd+=(--username "$MONGO_USER")
        restore_cmd+=(--password "$MONGO_PASS")
        restore_cmd+=(--authenticationDatabase "admin")
        log_info "使用認證: $MONGO_USER"
    fi

    # 檢查是否有 gzip 壓縮檔案
    if find "$backup_path" -name "*.gz" -print -quit | grep -q .; then
        restore_cmd+=(--gzip)
        log_info "偵測到 gzip 壓縮"
    fi

    # 匯入前 drop
    if [[ "$DROP_BEFORE_RESTORE" == "true" ]]; then
        restore_cmd+=(--drop)
        log_info "將在匯入前 drop 現有 collections"
    fi

    # 指定要還原的資料庫
    for db in "${selected_databases[@]}"; do
        restore_cmd+=(--nsInclude "${db}.*")
    done

    restore_cmd+=("$backup_path")

    # 5. 執行還原
    log_info "================================"
    log_info "開始還原..."
    log_info "執行命令: ${restore_cmd[*]}"
    log_info "================================"

    if "${restore_cmd[@]}"; then
        log_success "還原完成！"
        exit 0
    else
        log_error "還原過程中發生錯誤"
        exit 1
    fi
}

main "$@"

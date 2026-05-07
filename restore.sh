#!/bin/bash
set -e

BACKUP_DIR="${BACKUP_DIR:-/backup}"

# ============================================
# Gum UI 函數
# ============================================

header() {
    gum style --foreground 212 --bold "$1"
}

choose() {
    gum choose "$@"
}

choose_multi() {
    gum choose --no-limit "$@"
}

confirm() {
    local prompt="$1"
    local default="${2:-no}"

    if [[ "$default" == "yes" ]]; then
        gum confirm --default=yes "$prompt" && return 0 || return 1
    else
        gum confirm --default=no "$prompt" && return 0 || return 1
    fi
}

input() {
    local prompt="$1"
    local default="$2"
    local value

    value=$(gum input --placeholder "$default" --prompt "$prompt: " --value "$default")
    echo "${value:-$default}"
}

input_password() {
    local prompt="$1"
    gum input --password --prompt "$prompt: "
}

spin() {
    local title="$1"
    shift
    gum spin --spinner dot --title "$title" -- "$@"
}

info() {
    gum style --foreground 117 "ℹ $1"
}

success() {
    gum style --foreground 76 "✓ $1"
}

error() {
    gum style --foreground 196 "✗ $1"
}

# ============================================
# 主程式
# ============================================

header "MongoDB 還原工具"
echo ""

# 1. 掃描備份目錄
if [[ ! -d "$BACKUP_DIR" ]]; then
    error "備份目錄不存在: $BACKUP_DIR"
    exit 1
fi

# 找出所有備份資料夾（排除隱藏檔和空目錄）
backup_folders=()
while IFS= read -r -d '' dir; do
    dirname=$(basename "$dir")
    # 排除隱藏目錄
    [[ "$dirname" == .* ]] && continue
    backup_folders+=("$dirname")
done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if [[ ${#backup_folders[@]} -eq 0 ]]; then
    error "找不到任何備份資料夾於 $BACKUP_DIR"
    exit 1
fi

# 2. 選擇備份
info "找到 ${#backup_folders[@]} 個備份資料夾"
echo ""
header "選擇要還原的備份"
selected_backup=$(choose "${backup_folders[@]}")
echo ""
info "已選擇: $selected_backup"
echo ""

# 3. 掃描該備份內的資料庫
backup_path="$BACKUP_DIR/$selected_backup"
databases=()
has_admin=false

while IFS= read -r -d '' dir; do
    dbname=$(basename "$dir")
    [[ "$dbname" == .* ]] && continue
    if [[ "$dbname" == "admin" ]]; then
        has_admin=true
    fi
    databases+=("$dbname")
done < <(find "$backup_path" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if [[ ${#databases[@]} -eq 0 ]]; then
    error "備份資料夾內沒有資料庫目錄: $backup_path"
    exit 1
fi

info "找到 ${#databases[@]} 個資料庫: ${databases[*]}"
echo ""

# 4. 選擇要匯入的資料庫
selected_databases=()
include_admin=false

if [[ ${#databases[@]} -gt 1 ]]; then
    header "選擇要匯入的資料庫"
    echo ""

    # 建立選項列表（加入「全部」選項，排除 admin 讓使用者單獨選擇）
    db_options=("[全部]")
    for db in "${databases[@]}"; do
        [[ "$db" != "admin" ]] && db_options+=("$db")
    done

    info "使用空白鍵選擇，Enter 確認"
    echo ""

    selected_raw=$(choose_multi "${db_options[@]}")

    # 解析選擇結果
    if echo "$selected_raw" | grep -q "\[全部\]"; then
        # 選擇了「全部」，加入所有非 admin 資料庫
        for db in "${databases[@]}"; do
            [[ "$db" != "admin" ]] && selected_databases+=("$db")
        done
        info "已選擇全部資料庫"
    else
        # 個別選擇
        while IFS= read -r db; do
            [[ -n "$db" ]] && selected_databases+=("$db")
        done <<< "$selected_raw"
        info "已選擇 ${#selected_databases[@]} 個資料庫: ${selected_databases[*]}"
    fi
    echo ""

    # 詢問是否匯入 admin（如果存在）
    if $has_admin; then
        header "Admin 資料庫"
        if confirm "是否要匯入 admin 資料庫？（通常不建議）" "no"; then
            include_admin=true
            selected_databases+=("admin")
            info "將會匯入 admin 資料庫"
        else
            info "將跳過 admin 資料庫"
        fi
        echo ""
    fi
else
    # 只有一個資料庫，直接使用
    selected_databases=("${databases[@]}")

    # 如果唯一的資料庫是 admin，詢問是否匯入
    if $has_admin && [[ ${#databases[@]} -eq 1 ]] && [[ "${databases[0]}" == "admin" ]]; then
        header "Admin 資料庫"
        if confirm "是否要匯入 admin 資料庫？（通常不建議）" "no"; then
            include_admin=true
            info "將會匯入 admin 資料庫"
        else
            info "將跳過 admin 資料庫"
            selected_databases=()
        fi
        echo ""
    fi
fi

if [[ ${#selected_databases[@]} -eq 0 ]]; then
    error "沒有選擇任何資料庫"
    exit 1
fi

# 5. 詢問是否在匯入前 drop 資料庫
drop_before_restore=true
header "Drop 選項"
if confirm "是否在匯入前先清除（drop）現有的 collections？" "yes"; then
    drop_before_restore=true
    info "將會在匯入前 drop 現有 collections"
else
    drop_before_restore=false
    info "將保留現有資料（可能會有重複）"
fi
echo ""

# 6. 輸入 MongoDB 連線資訊
header "MongoDB 連線設定"
echo ""

MONGO_HOST="${MONGO_HOST:-$(input 'MongoDB Host' 'localhost')}"
MONGO_PORT="${MONGO_PORT:-$(input 'MongoDB Port' '27017')}"

# 認證設定
if [[ -z "$MONGO_USER" ]]; then
    MONGO_USER=$(input 'MongoDB 使用者名稱 (留空跳過認證)' '')
fi

if [[ -n "$MONGO_USER" && -z "$MONGO_PASS" ]]; then
    MONGO_PASS=$(input_password 'MongoDB 密碼')
fi

echo ""
info "連線目標: $MONGO_HOST:$MONGO_PORT"
[[ -n "$MONGO_USER" ]] && info "認證使用者: $MONGO_USER"
echo ""

# 7. 確認執行
header "確認還原"
echo ""
echo "備份來源: $backup_path"
echo "目標主機: $MONGO_HOST:$MONGO_PORT"
echo "資料庫: ${selected_databases[*]}"
$drop_before_restore && echo "Drop: 是（匯入前清除現有 collections）"
echo ""

if ! confirm "確定要開始還原嗎？" "no"; then
    info "已取消還原"
    exit 0
fi

echo ""

# 8. 建構 mongorestore 命令
restore_cmd=(mongorestore)
restore_cmd+=(--host "$MONGO_HOST")
restore_cmd+=(--port "$MONGO_PORT")

if [[ -n "$MONGO_USER" ]]; then
    restore_cmd+=(--username "$MONGO_USER")
    restore_cmd+=(--password "$MONGO_PASS")
    restore_cmd+=(--authenticationDatabase "admin")
fi

# 檢查是否有 gzip 壓縮檔案
if find "$backup_path" -name "*.gz" -print -quit | grep -q .; then
    restore_cmd+=(--gzip)
fi

# 匯入前 drop
if $drop_before_restore; then
    restore_cmd+=(--drop)
fi

# 指定要還原的資料庫
for db in "${selected_databases[@]}"; do
    restore_cmd+=(--nsInclude "${db}.*")
done

restore_cmd+=("$backup_path")

# 9. 執行還原
header "開始還原..."
echo ""
echo "執行命令: ${restore_cmd[*]}"
echo ""

if "${restore_cmd[@]}"; then
    echo ""
    success "還原完成！"
else
    echo ""
    error "還原過程中發生錯誤"
    exit 1
fi

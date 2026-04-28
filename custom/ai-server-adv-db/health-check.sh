#!/usr/bin/env bash
#
# PostgreSQL HA 集群健康检查脚本
# 
# 用途：快速检查集群健康状态和备份可用性
# 
# 使用方法：
#   ./health-check.sh [选项]
#
# 选项：
#   --cluster-name NAME      集群名称（默认: ai-postgres）
#   --namespace NAMESPACE    命名空间（默认: postgres-operator）
#   --detailed              显示详细信息

set -euo pipefail

# 默认配置
CLUSTER_NAME="ai-postgres"
NAMESPACE="postgres-operator"
DETAILED=false
ARCHIVE_SAMPLE_SECONDS=5
DEFAULT_WAL_SEGMENT_BYTES=$((16 * 1024 * 1024))

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --detailed)
            DETAILED=true
            shift
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

# 状态符号
OK="✅"
WARN="⚠️ "
ERROR="❌"
INFO="ℹ️ "

# 检查函数
check_item() {
    local status=$1
    local message=$2
    
    case $status in
        "ok")
            echo -e "${OK} ${GREEN}${message}${NC}"
            ;;
        "warn")
            echo -e "${WARN} ${YELLOW}${message}${NC}"
            ;;
        "error")
            echo -e "${ERROR} ${RED}${message}${NC}"
            ;;
        "info")
            echo -e "${INFO} ${BLUE}${message}${NC}"
            ;;
    esac
}

get_database_pod() {
    local ready_pod
    ready_pod=$(kubectl get pods -n "$NAMESPACE" \
        -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/data=postgres \
        --no-headers 2>/dev/null | awk '{split($2, a, "/"); if ($3 == "Running" && a[1] == a[2]) print $1}' | head -1)

    if [ -n "$ready_pod" ]; then
        echo "pod/$ready_pod"
        return 0
    fi

    local running_pod
    running_pod=$(kubectl get pods -n "$NAMESPACE" \
        -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/data=postgres \
        --no-headers 2>/dev/null | awk '$3 == "Running" {print $1}' | head -1)

    if [ -n "$running_pod" ]; then
        echo "pod/$running_pod"
        return 0
    fi

    return 1
}

get_repo_pod() {
    local repo_pod
    repo_pod=$(kubectl get pods -n "$NAMESPACE" \
        -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/data=pgbackrest \
        --no-headers 2>/dev/null | awk '$3 == "Running" {print $1}' | head -1)

    if [ -n "$repo_pod" ]; then
        echo "pod/$repo_pod"
        return 0
    fi

    return 1
}

usage_status_from_percent() {
    local use_percent=$1
    local warn_threshold=$2
    local error_threshold=$3

    if [ "$use_percent" -ge "$error_threshold" ]; then
        echo "error"
    elif [ "$use_percent" -ge "$warn_threshold" ]; then
        echo "warn"
    else
        echo "ok"
    fi
}

get_pod_claim_name() {
    local pod=$1
    local volume_name=$2

    kubectl get "$pod" -n "$NAMESPACE" \
        -o jsonpath='{range .spec.volumes[*]}{.name}{"|"}{.persistentVolumeClaim.claimName}{"\n"}{end}' 2>/dev/null \
        | awk -F'|' -v target_volume="$volume_name" '$1 == target_volume {print $2; exit}'
}

get_pvc_capacity_info() {
    local claim_name=$1

    kubectl get pvc "$claim_name" -n "$NAMESPACE" \
        -o jsonpath='{.spec.volumeName}{"|"}{.status.phase}{"|"}{.status.capacity.storage}{"|"}{.spec.resources.requests.storage}' 2>/dev/null || true
}

get_mount_usage_info() {
    local pod=$1
    local container=$2
    local mount_path=$3

    kubectl exec -n "$NAMESPACE" "$pod" -c "$container" -- df -hP "$mount_path" 2>/dev/null | awk '
NR == 2 {
    gsub(/%/, "", $5)
    printf "filesystem=%s\n", $1
    printf "size=%s\n", $2
    printf "used=%s\n", $3
    printf "avail=%s\n", $4
    printf "use_percent=%s\n", $5
    printf "mount=%s\n", $6
}'
}

report_pvc_usage() {
    local pod=$1
    local container=$2
    local volume_name=$3
    local mount_path=$4
    local pvc_type=$5

    local pod_name=${pod#pod/}
    local claim_name=""
    claim_name=$(get_pod_claim_name "$pod" "$volume_name")

    if [ -z "$claim_name" ]; then
        check_item "warn" "Pod $pod_name 的卷 $volume_name 未关联 PVC，跳过使用率检查"
        return 0
    fi

    local pvc_info=""
    pvc_info=$(get_pvc_capacity_info "$claim_name")

    local pv_name=""
    local pvc_phase=""
    local pvc_capacity=""
    local pvc_request=""
    IFS='|' read -r pv_name pvc_phase pvc_capacity pvc_request <<< "$pvc_info"

    if [ "$pvc_phase" != "Bound" ]; then
        check_item "warn" "PVC $claim_name 当前未 Bound，跳过挂载使用率检查"
        return 0
    fi

    local mount_info=""
    mount_info=$(get_mount_usage_info "$pod" "$container" "$mount_path")

    if [ -z "$mount_info" ]; then
        check_item "warn" "无法读取 Pod $pod_name 挂载点 $mount_path 的使用情况"
        return 0
    fi

    local use_percent=""
    local size=""
    local used=""
    local avail=""
    use_percent=$(awk -F= '$1 == "use_percent" {print $2}' <<< "$mount_info")
    size=$(awk -F= '$1 == "size" {print $2}' <<< "$mount_info")
    used=$(awk -F= '$1 == "used" {print $2}' <<< "$mount_info")
    avail=$(awk -F= '$1 == "avail" {print $2}' <<< "$mount_info")

    if ! [[ "$use_percent" =~ ^[0-9]+$ ]]; then
        check_item "warn" "挂载点 $mount_path 的使用率格式异常，原始值: ${use_percent:-空}"
        return 0
    fi

    local warn_threshold=70
    local error_threshold=85
    local pvc_label="数据盘"

    if [ "$pvc_type" = "repo" ]; then
        warn_threshold=65
        error_threshold=80
        pvc_label="备份盘"
    fi

    local status=""
    status=$(usage_status_from_percent "$use_percent" "$warn_threshold" "$error_threshold")

    check_item "$status" "$pvc_label PVC $claim_name (PV ${pv_name:-未知}) 使用率 ${use_percent}% (${used}/${size}, 挂载 ${mount_path})"

    if [ "$DETAILED" = true ]; then
        echo "     Pod: $pod_name, PVC容量: ${pvc_capacity:-未知}, 请求容量: ${pvc_request:-未知}, 可用: ${avail:-未知}"
    fi
}

extract_archive_max_wal() {
    local backup_info=$1

    awk -F': ' '/wal archive min\/max/ {
        split($2, wal_range, "/")
        print wal_range[2]
        exit
    }' <<< "$backup_info"
}

get_local_wal_stats() {
    local pod=$1

    kubectl exec -n "$NAMESPACE" "$pod" -c database -- sh -c '
for data_dir in /pgdata/*; do
    if [ -d "$data_dir/pg_wal" ]; then
        segment_bytes=$(pg_controldata "$data_dir" 2>/dev/null | awk -F": *" "/Bytes per WAL segment/ {print \$2; exit}")
        latest_wal=$(ls "$data_dir/pg_wal" 2>/dev/null | grep -E "^[0-9A-F]{24}$" | sort | tail -n 1)
        printf "segment_bytes=%s\n" "$segment_bytes"
        printf "latest_wal=%s\n" "$latest_wal"
        exit 0
    fi
done
exit 1
' 2>/dev/null || true
}

wal_segment_distance() {
    local from_wal=$1
    local to_wal=$2

    local from_tli=${from_wal:0:8}
    local to_tli=${to_wal:0:8}

    if [ "$from_tli" != "$to_tli" ]; then
        return 1
    fi

    local from_log=$((16#${from_wal:8:8}))
    local from_seg=$((16#${from_wal:16:8}))
    local to_log=$((16#${to_wal:8:8}))
    local to_seg=$((16#${to_wal:16:8}))

    echo $((((to_log - from_log) * 256) + (to_seg - from_seg)))
}

format_bytes() {
    local bytes=$1

    awk -v bytes="$bytes" '
function human(value, units, unit_index) {
    split("B KiB MiB GiB TiB PiB", units, " ")
    unit_index = 1

    while (value >= 1024 && unit_index < 6) {
        value /= 1024
        unit_index++
    }

    if (unit_index == 1 || value >= 100) {
        printf "%.0f %s", value, units[unit_index]
    } else {
        printf "%.1f %s", value, units[unit_index]
    }
}

BEGIN {
    human(bytes)
}'
}

format_duration() {
    local total_seconds=$1
    local days=0
    local hours=0
    local minutes=0
    local seconds=0

    if [ "$total_seconds" -lt 60 ]; then
        printf "%d 秒" "$total_seconds"
        return
    fi

    days=$((total_seconds / 86400))
    hours=$(((total_seconds % 86400) / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))

    if [ "$days" -gt 0 ]; then
        printf "%d 天 %d 小时 %d 分" "$days" "$hours" "$minutes"
    elif [ "$hours" -gt 0 ]; then
        printf "%d 小时 %d 分" "$hours" "$minutes"
    else
        printf "%d 分 %d 秒" "$minutes" "$seconds"
    fi
}

estimate_archive_progress() {
    local repo_pod=$1
    local initial_backup_info=$2

    local database_pod=""
    database_pod=$(get_database_pod || true)

    if [ -z "$database_pod" ]; then
        check_item "warn" "找不到数据库 Pod，跳过归档速度估算"
        return 0
    fi

    local archive_start_wal=""
    archive_start_wal=$(extract_archive_max_wal "$initial_backup_info")

    if [ -z "$archive_start_wal" ]; then
        check_item "warn" "无法解析归档上限，跳过归档速度估算"
        return 0
    fi

    local local_wal_stats=""
    local_wal_stats=$(get_local_wal_stats "$database_pod")

    if [ -z "$local_wal_stats" ]; then
        check_item "warn" "无法读取本地 WAL 信息，跳过归档速度估算"
        return 0
    fi

    local latest_local_wal=""
    latest_local_wal=$(awk -F= '$1 == "latest_wal" {print $2}' <<< "$local_wal_stats")

    if [ -z "$latest_local_wal" ]; then
        check_item "warn" "本地 WAL 目录为空，跳过归档速度估算"
        return 0
    fi

    local wal_segment_bytes=""
    wal_segment_bytes=$(awk -F= '$1 == "segment_bytes" {print $2}' <<< "$local_wal_stats")
    if ! [[ "$wal_segment_bytes" =~ ^[0-9]+$ ]]; then
        wal_segment_bytes=$DEFAULT_WAL_SEGMENT_BYTES
    fi

    sleep "$ARCHIVE_SAMPLE_SECONDS"

    local end_backup_info=""
    end_backup_info=$(kubectl exec -n "$NAMESPACE" "$repo_pod" -- pgbackrest --stanza=db info 2>/dev/null || echo "")
    if [ -z "$end_backup_info" ]; then
        check_item "warn" "无法获取第二次归档采样，跳过速度估算"
        return 0
    fi

    local archive_end_wal=""
    archive_end_wal=$(extract_archive_max_wal "$end_backup_info")
    if [ -z "$archive_end_wal" ]; then
        check_item "warn" "无法解析第二次归档上限，跳过速度估算"
        return 0
    fi

    local archived_segments=0
    if ! archived_segments=$(wal_segment_distance "$archive_start_wal" "$archive_end_wal"); then
        check_item "warn" "归档时间线发生变化，跳过速度估算"
        return 0
    fi

    local backlog_segments=0
    if ! backlog_segments=$(wal_segment_distance "$archive_end_wal" "$latest_local_wal"); then
        check_item "warn" "本地 WAL 与归档 WAL 不在同一时间线，跳过 ETA 估算"
        return 0
    fi

    if [ "$backlog_segments" -lt 0 ]; then
        backlog_segments=0
    fi

    local backlog_bytes=$((backlog_segments * wal_segment_bytes))

    if [ "$archived_segments" -le 0 ]; then
        check_item "warn" "采样 ${ARCHIVE_SAMPLE_SECONDS} 秒内未观察到归档推进，剩余约 ${backlog_segments} 段 ($(format_bytes "$backlog_bytes"))"
        return 0
    fi

    local archive_rate_segments
    archive_rate_segments=$(awk -v segments="$archived_segments" -v seconds="$ARCHIVE_SAMPLE_SECONDS" 'BEGIN {printf "%.2f", segments / seconds}')
    local archive_rate_bytes=$((archived_segments * wal_segment_bytes / ARCHIVE_SAMPLE_SECONDS))
    local eta_seconds=$((((backlog_segments * ARCHIVE_SAMPLE_SECONDS) + archived_segments - 1) / archived_segments))

    check_item "info" "当前归档速度: ${archive_rate_segments} 段/秒 ($(format_bytes "$archive_rate_bytes")/秒, 采样 ${ARCHIVE_SAMPLE_SECONDS} 秒)"

    if [ "$backlog_segments" -eq 0 ]; then
        check_item "ok" "WAL 归档已基本追平"
    else
        check_item "warn" "预计剩余 WAL 积压: ${backlog_segments} 段 ($(format_bytes "$backlog_bytes")), 按当前速度约 $(format_duration "$eta_seconds")"
    fi

    if [ "$DETAILED" = true ]; then
        echo "     已归档到: $archive_end_wal"
        echo "     本地最新 WAL: $latest_local_wal"
    fi
}

# 检查 Pod 状态
check_pods() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Pod 状态检查"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local pods=$(kubectl get pods -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME" --no-headers 2>/dev/null || echo "")
    
    if [ -z "$pods" ]; then
        check_item "error" "未找到任何 Pod"
        return 1
    fi
    
    local active_pods
    active_pods=$(echo "$pods" | awk '$1 !~ /-repo[0-9]+-(full|diff|incr)-/')

    local total_pods=$(echo "$active_pods" | wc -l)
    local ready_pods=$(echo "$active_pods" | awk '{if ($2 ~ /\//) {split($2, a, "/"); if (a[1] == a[2] && $3 == "Running") print}}' | wc -l)
    
    if [ "$ready_pods" -eq "$total_pods" ]; then
        check_item "ok" "所有 Pod 正常 ($ready_pods/$total_pods)"
    else
        check_item "warn" "部分 Pod 未就绪 ($ready_pods/$total_pods)"
    fi
    
    if [ "$DETAILED" = true ]; then
        echo ""
        kubectl get pods -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME"
    fi
}

# 检查 Patroni 状态
check_patroni() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Patroni 集群状态"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local pod=""
    pod=$(get_database_pod || true)
    
    if [ -z "$pod" ]; then
        check_item "error" "找不到可用的 Pod 执行检查"
        return 1
    fi
    
    local patroni_output=$(kubectl exec -n "$NAMESPACE" "$pod" -c database -- patronictl list 2>/dev/null || echo "")
    
    if [ -z "$patroni_output" ]; then
        check_item "error" "无法获取 Patroni 状态"
        return 1
    fi
    
    local leader_count=$(echo "$patroni_output" | grep -c "Leader")
    local replica_count=$(echo "$patroni_output" | grep -c "Replica")
    local streaming_count=$(echo "$patroni_output" | grep -c "streaming")
    
    if [ "$leader_count" -eq 1 ]; then
        check_item "ok" "Leader: $leader_count"
    else
        check_item "error" "Leader: $leader_count (应该是 1)"
    fi
    
    check_item "info" "Replica: $replica_count"
    
    if [ "$streaming_count" -eq "$replica_count" ]; then
        check_item "ok" "所有 Replica 正在同步"
    else
        check_item "warn" "部分 Replica 未同步 ($streaming_count/$replica_count)"
    fi
    
    echo ""
    echo "$patroni_output"
}

# 检查备份
check_backups() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  备份状态检查"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local repo_pod=""
    repo_pod=$(get_repo_pod || true)
    
    if [ -z "$repo_pod" ]; then
        check_item "error" "找不到备份 repo Pod"
        return 1
    fi
    
    local repo_status=$(kubectl get "$repo_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$repo_status" = "Running" ]; then
        check_item "ok" "备份 Pod 运行正常"
    else
        check_item "error" "备份 Pod 状态异常: $repo_status"
        return 1
    fi
    
    local backup_info=$(kubectl exec -n "$NAMESPACE" "$repo_pod" -- pgbackrest --stanza=db info 2>/dev/null || echo "")
    
    if [ -z "$backup_info" ]; then
        check_item "error" "无法获取备份信息"
        return 1
    fi
    
    local stanza_status=$(echo "$backup_info" | grep "status:" | awk '{print $2}')
    if [ "$stanza_status" = "ok" ]; then
        check_item "ok" "备份 Stanza 状态正常"
    else
        check_item "error" "备份 Stanza 状态异常: $stanza_status"
    fi
    
    local full_backup_count
    full_backup_count=$(echo "$backup_info" | awk '/full backup:/ {count++} END {print count+0}')
    if [ "$full_backup_count" -gt 0 ]; then
        check_item "ok" "全量备份: $full_backup_count 个"
    else
        check_item "error" "没有全量备份"
    fi
    
    local incr_backup_count
    incr_backup_count=$(echo "$backup_info" | awk '/incr backup:/ {count++} END {print count+0}')
    check_item "info" "增量备份: $incr_backup_count 个"

    estimate_archive_progress "$repo_pod" "$backup_info"
    
    if [ "$DETAILED" = true ]; then
        echo ""
        echo "$backup_info"
    fi
}

# 检查 PVC
check_pvcs() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  PVC 存储检查"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local pvcs=$(kubectl get pvc -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME" --no-headers 2>/dev/null || echo "")
    
    if [ -z "$pvcs" ]; then
        check_item "error" "未找到任何 PVC"
        return 1
    fi
    
    local total_pvcs=$(echo "$pvcs" | wc -l)
    local bound_pvcs
    bound_pvcs=$(echo "$pvcs" | awk '$2 == "Bound" {count++} END {print count+0}')
    
    if [ "$bound_pvcs" -eq "$total_pvcs" ]; then
        check_item "ok" "所有 PVC 已绑定 ($bound_pvcs/$total_pvcs)"
    else
        check_item "warn" "部分 PVC 未绑定 ($bound_pvcs/$total_pvcs)"
    fi

    local database_pods=""
    database_pods=$(kubectl get pods -n "$NAMESPACE" \
        -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/data=postgres \
        --no-headers 2>/dev/null | awk '$3 == "Running" {print "pod/" $1}')

    if [ -n "$database_pods" ]; then
        while IFS= read -r database_pod; do
            [ -z "$database_pod" ] && continue
            report_pvc_usage "$database_pod" "database" "postgres-data" "/pgdata" "data"
        done <<< "$database_pods"
    else
        check_item "warn" "未找到运行中的数据库 Pod，跳过数据盘使用率检查"
    fi

    local repo_pod=""
    repo_pod=$(get_repo_pod || true)

    if [ -n "$repo_pod" ]; then
        report_pvc_usage "$repo_pod" "pgbackrest" "repo1" "/pgbackrest/repo1" "repo"
    else
        check_item "warn" "未找到运行中的备份 Pod，跳过备份盘使用率检查"
    fi
    
    if [ "$DETAILED" = true ]; then
        echo ""
        kubectl get pvc -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME"
    fi
}

# 检查连接性
check_connectivity() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  数据库连接检查"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local pod=""
    pod=$(get_database_pod || true)
    
    if [ -z "$pod" ]; then
        check_item "error" "找不到可用的 Pod"
        return 1
    fi
    
    local version=$(kubectl exec -n "$NAMESPACE" "$pod" -c database -- psql -U postgres -t -c "SELECT version();" 2>/dev/null | head -1 | xargs)
    
    if [ -n "$version" ]; then
        check_item "ok" "数据库连接正常"
        if [ "$DETAILED" = true ]; then
            echo "     版本: $version"
        fi
    else
        check_item "error" "无法连接到数据库"
    fi
}

# 主函数
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  PostgreSQL HA 集群健康检查"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  集群: $CLUSTER_NAME"
    echo "  命名空间: $NAMESPACE"
    echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    check_pods
    check_patroni
    check_backups
    check_pvcs
    check_connectivity
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  检查完成"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

main

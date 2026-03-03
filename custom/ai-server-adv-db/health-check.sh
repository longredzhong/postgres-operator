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
    
    local total_pods=$(echo "$pods" | wc -l)
    local ready_pods=$(echo "$pods" | awk '{if ($2 ~ /\//) {split($2, a, "/"); if (a[1] == a[2] && $3 == "Running") print}}' | wc -l)
    
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
    
    local pod=$(kubectl get pods -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/role=master -o name 2>/dev/null | head -1 || \
                kubectl get pods -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/instance-set=pgha -o name 2>/dev/null | head -1)
    
    if [ -z "$pod" ]; then
        check_item "error" "找不到可用的 Pod 执行检查"
        return 1
    fi
    
    local patroni_output=$(kubectl exec -n "$NAMESPACE" "$pod" -c database -- patronictl list 2>/dev/null || echo "")
    
    if [ -z "$patroni_output" ]; then
        check_item "error" "无法获取 Patroni 状态"
        return 1
    fi
    
    local leader_count=$(echo "$patroni_output" | grep -c "Leader" || echo "0")
    local replica_count=$(echo "$patroni_output" | grep -c "Replica" || echo "0")
    local streaming_count=$(echo "$patroni_output" | grep -c "streaming" || echo "0")
    
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
    
    local repo_pod=$(kubectl get pods -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/data=pgbackrest -o name 2>/dev/null | head -1)
    
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
    
    local full_backup_count=$(echo "$backup_info" | grep -c "full backup:" || echo "0")
    if [ "$full_backup_count" -gt 0 ]; then
        check_item "ok" "全量备份: $full_backup_count 个"
    else
        check_item "error" "没有全量备份"
    fi
    
    local incr_backup_count=$(echo "$backup_info" | grep -c "incr backup:" || echo "0")
    check_item "info" "增量备份: $incr_backup_count 个"
    
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
    local bound_pvcs=$(echo "$pvcs" | grep -c "Bound" || echo "0")
    
    if [ "$bound_pvcs" -eq "$total_pvcs" ]; then
        check_item "ok" "所有 PVC 已绑定 ($bound_pvcs/$total_pvcs)"
    else
        check_item "warn" "部分 PVC 未绑定 ($bound_pvcs/$total_pvcs)"
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
    
    local pod=$(kubectl get pods -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/role=master -o name 2>/dev/null | head -1 || \
                kubectl get pods -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/instance-set=pgha -o name 2>/dev/null | head -1)
    
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

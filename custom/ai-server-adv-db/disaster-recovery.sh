#!/usr/bin/env bash
#
# PostgreSQL HA 集群灾难恢复脚本
# 
# 用途：自动化执行从 pgBackRest 备份恢复整个集群的流程
# 
# 使用方法：
#   ./disaster-recovery.sh [选项]
#
# 选项：
#   --cluster-name NAME      集群名称（默认: ai-postgres）
#   --namespace NAMESPACE    命名空间（默认: postgres-operator）
#   --replicas N            目标副本数（默认: 3）
#   --backup-time "TIME"    恢复到指定时间点（可选，格式: "2026-03-03 07:00:00"）
#   --backup-set LABEL       指定 pgBackRest 备份集标签（默认: 自动选择最新成功备份）
#   --dry-run               仅显示将要执行的操作，不实际执行
#   --skip-confirmation     跳过确认提示（危险！）
#
# 示例：
#   # 交互式恢复到最新备份
#   ./disaster-recovery.sh
#
#   # 恢复到指定时间点
#   ./disaster-recovery.sh --backup-time "2026-03-02 15:30:00"
#
#   # 使用指定备份集恢复
#   ./disaster-recovery.sh --backup-set 20250901-030749F_20251229-034213I
#
#   # 仅查看将要执行的操作
#   ./disaster-recovery.sh --dry-run

set -euo pipefail

# 默认配置
CLUSTER_NAME="ai-postgres"
NAMESPACE="postgres-operator"
REPLICAS=3
BACKUP_TIME=""
BACKUP_SET=""
DRY_RUN=false
SKIP_CONFIRM=false

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
        --replicas)
            REPLICAS="$2"
            shift 2
            ;;
        --backup-time)
            BACKUP_TIME="$2"
            shift 2
            ;;
        --backup-set)
            BACKUP_SET="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-confirmation)
            SKIP_CONFIRM=true
            shift
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

require_python3() {
    if ! command -v python3 &> /dev/null; then
        log_error "需要 python3 来解析 pgBackRest JSON 输出"
        exit 1
    fi
}

get_repo_pod() {
    kubectl get pods -n "$NAMESPACE" \
        -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/data=pgbackrest \
        -o name 2>/dev/null | head -1
}

resolve_latest_backup_set() {
    require_python3

    local repo_pod
    repo_pod=$(get_repo_pod)

    if [ -z "$repo_pod" ]; then
        log_error "找不到备份 repo Pod"
        exit 1
    fi

    local backup_json
    if ! backup_json=$(kubectl exec -n "$NAMESPACE" "$repo_pod" -- pgbackrest --stanza=db info --output=json 2>/dev/null); then
        log_error "无法读取 pgBackRest 备份元数据"
        exit 1
    fi

    local latest_label
    latest_label=$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

backups = []
for stanza in data:
    for backup in stanza.get("backup", []):
        if backup.get("error") is False:
            backups.append(backup)

if not backups:
    sys.exit(2)

latest = max(backups, key=lambda item: item.get("timestamp", {}).get("stop", 0))
print(latest.get("label", ""))
' <<< "$backup_json")

    if [ -z "$latest_label" ]; then
        log_error "没有找到可用于恢复的成功备份集"
        exit 1
    fi

    echo "$latest_label"
}

# 执行命令函数
run_cmd() {
    local cmd="$1"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $cmd"
    else
        log_info "执行: $cmd"
        eval "$cmd"
    fi
}

# 检查前提条件
check_prerequisites() {
    log_info "检查前提条件..."
    
    # 检查 kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 未安装"
        exit 1
    fi
    
    # 检查集群连接
    if ! kubectl cluster-info &> /dev/null; then
        log_error "无法连接到 Kubernetes 集群"
        exit 1
    fi
    
    # 检查命名空间
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "命名空间 $NAMESPACE 不存在"
        exit 1
    fi
    
    # 检查 PostgresCluster
    if ! kubectl get postgrescluster "$CLUSTER_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_error "PostgresCluster $CLUSTER_NAME 不存在于命名空间 $NAMESPACE"
        exit 1
    fi
    
    log_info "所有前提条件检查通过"
}

# 检查备份
check_backups() {
    log_info "检查可用备份..."
    
    local repo_pod=$(get_repo_pod)
    
    if [ -z "$repo_pod" ]; then
        log_error "找不到备份 repo Pod"
        exit 1
    fi
    
    log_info "备份 Pod: $repo_pod"
    
    if [ "$DRY_RUN" = false ]; then
        echo ""
        kubectl exec -n "$NAMESPACE" "$repo_pod" -- pgbackrest --stanza=db info || {
            log_error "无法获取备份信息或没有可用备份"
            exit 1
        }
        echo ""
    fi

    if [ -z "$BACKUP_SET" ]; then
        BACKUP_SET=$(resolve_latest_backup_set)
        log_info "自动选择最新成功备份集: $BACKUP_SET"
    else
        log_info "使用指定备份集: $BACKUP_SET"
    fi
}

# 显示确认信息
confirm_operation() {
    if [ "$SKIP_CONFIRM" = true ]; then
        return 0
    fi
    
    echo ""
    log_warn "=========================================="
    log_warn "  危险操作 - 灾难恢复"
    log_warn "=========================================="
    echo ""
    echo "  集群名称: $CLUSTER_NAME"
    echo "  命名空间: $NAMESPACE"
    echo "  目标副本数: $REPLICAS"
    echo "  备份集: ${BACKUP_SET:-自动检测}"
    if [ -n "$BACKUP_TIME" ]; then
        echo "  恢复时间点: $BACKUP_TIME"
    else
        echo "  恢复时间点: 备份集结束时刻（最新备份）"
    fi
    echo ""
    log_warn "此操作将："
    echo "  1. 停止所有 PostgreSQL 实例"
    echo "  2. 删除所有数据 PVC（数据将丢失！）"
    echo "  3. 从备份恢复数据"
    echo ""
    log_error "⚠️  这将删除当前所有数据库数据！"
    log_error "⚠️  请确保备份可用且是您期望的版本！"
    echo ""
    
    read -p "确认执行此操作？[yes/NO]: " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "操作已取消"
        exit 0
    fi
    
    read -p "再次确认（输入集群名称 '$CLUSTER_NAME'）: " confirm_name
    if [ "$confirm_name" != "$CLUSTER_NAME" ]; then
        log_error "集群名称不匹配，操作已取消"
        exit 1
    fi
}

# 步骤 1: 缩减副本数到 0
scale_down() {
    log_info "步骤 1: 缩减副本数到 0..."
    
    run_cmd "kubectl patch postgrescluster $CLUSTER_NAME -n $NAMESPACE --type='json' -p='[{\"op\": \"replace\", \"path\": \"/spec/instances/0/replicas\", \"value\": 0}]'"
    
    if [ "$DRY_RUN" = false ]; then
        log_info "等待所有实例 Pod 终止..."
        sleep 10
        
        local timeout=120
        local elapsed=0
        while [ $elapsed -lt $timeout ]; do
            local pod_count=$(kubectl get pods -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/instance-set=pgha --no-headers 2>/dev/null | wc -l)
            if [ "$pod_count" -eq 0 ]; then
                log_info "所有实例 Pod 已终止"
                break
            fi
            echo -n "."
            sleep 5
            elapsed=$((elapsed + 5))
        done
        echo ""
        
        if [ $elapsed -ge $timeout ]; then
            log_warn "等待超时，但继续执行"
        fi
    fi
}

# 步骤 2: 删除数据 PVC
delete_data_pvcs() {
    log_info "步骤 2: 删除所有数据 PVC..."
    
    local pvcs=$(kubectl get pvc -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME" -o name | grep pgdata || true)
    
    if [ -z "$pvcs" ]; then
        log_info "没有找到数据 PVC，跳过"
        return
    fi
    
    for pvc in $pvcs; do
        run_cmd "kubectl delete $pvc -n $NAMESPACE"
    done
    
    if [ "$DRY_RUN" = false ]; then
        log_info "等待 PVC 删除完成..."
        sleep 10
    fi
}

# 步骤 3: 更新配置添加 dataSource
update_config() {
    log_info "步骤 3: 更新 PostgresCluster 配置..."

    local patch
    patch=$(CLUSTER_NAME="$CLUSTER_NAME" BACKUP_SET="$BACKUP_SET" BACKUP_TIME="$BACKUP_TIME" python3 - <<'PY'
import json
import os

cluster_name = os.environ["CLUSTER_NAME"]
backup_set = os.environ["BACKUP_SET"]
backup_time = os.environ.get("BACKUP_TIME", "")

options = [f"--set={backup_set}"]
if backup_time:
    options.extend([
        "--type=time",
        f"--target={backup_time}",
    ])

patch = {
    "spec": {
        "dataSource": {
            "pgbackrest": {
                "stanza": "db",
                "configuration": [
                    {"secret": {"name": f"{cluster_name}-pgbackrest-secret"}}
                ],
                "global": {
                    "repo1-path": "/pgbackrest/repo1"
                },
                "repo": {
                    "name": "repo1",
                    "options": options,
                },
            }
        }
    }
}

print(json.dumps(patch, ensure_ascii=False))
PY
)

    log_info "恢复将使用备份集: $BACKUP_SET"
    if [ -n "$BACKUP_TIME" ]; then
        log_info "并恢复到时间点: $BACKUP_TIME"
    fi

    run_cmd "kubectl patch postgrescluster $CLUSTER_NAME -n $NAMESPACE --type=merge -p '$patch'"
}

# 步骤 4: 恢复副本数
scale_up() {
    log_info "步骤 4: 恢复副本数到 $REPLICAS..."
    
    run_cmd "kubectl patch postgrescluster $CLUSTER_NAME -n $NAMESPACE --type='json' -p='[{\"op\": \"replace\", \"path\": \"/spec/instances/0/replicas\", \"value\": $REPLICAS}]'"
}

# 步骤 5: 监控恢复进度
monitor_recovery() {
    if [ "$DRY_RUN" = true ]; then
        log_info "DRY-RUN 模式，跳过监控"
        return
    fi
    
    log_info "步骤 5: 监控恢复进度..."
    log_info "等待 Pod 创建（这可能需要几分钟）..."
    
    sleep 20
    
    echo ""
    log_info "当前 Pod 状态:"
    kubectl get pods -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME"
    
    echo ""
    log_info "恢复监控命令:"
    echo "  # 查看 Pod 状态"
    echo "  kubectl get pods -n $NAMESPACE -l postgres-operator.crunchydata.com/cluster=$CLUSTER_NAME -w"
    echo ""
    echo "  # 查看恢复日志（替换 <pod-name>）"
    echo "  kubectl logs -n $NAMESPACE <pod-name> -c database -f"
    echo ""
    echo "  # 检查 Patroni 状态"
    echo "  kubectl exec -n $NAMESPACE <pod-name> -c database -- patronictl list"
}

# 步骤 6: 清理 dataSource
cleanup_reminder() {
    echo ""
    log_warn "=========================================="
    log_warn "  重要提醒"
    log_warn "=========================================="
    echo ""
    log_warn "恢复完成后，请执行以下步骤:"
    echo ""
    echo "  1. 验证数据恢复成功:"
    echo "     kubectl exec -n $NAMESPACE <pod-name> -c database -- patronictl list"
    echo ""
    echo "  2. 验证数据库可连接:"
    echo "     kubectl exec -n $NAMESPACE <pod-name> -c database -- psql -U postgres -c \"SELECT version();\""
    echo ""
    echo "  3. ⚠️ 删除 dataSource 配置（非常重要！）:"
    echo "     kubectl patch postgrescluster $CLUSTER_NAME -n $NAMESPACE --type=json -p='[{\"op\": \"remove\", \"path\": \"/spec/dataSource\"}]'"
    echo ""
    log_error "如果不删除 dataSource，集群重启时会重复执行恢复！"
    echo ""
}

# 主函数
main() {
    echo ""
    log_info "=========================================="
    log_info "  PostgreSQL HA 集群灾难恢复"
    log_info "=========================================="
    echo ""
    
    check_prerequisites
    check_backups
    confirm_operation
    
    echo ""
    log_info "开始恢复流程..."
    echo ""
    
    scale_down
    delete_data_pvcs
    update_config
    scale_up
    monitor_recovery
    cleanup_reminder
    
    echo ""
    log_info "恢复流程已启动！"
    log_info "请按照上述提醒完成后续步骤"
    echo ""
}

# 运行主函数
main

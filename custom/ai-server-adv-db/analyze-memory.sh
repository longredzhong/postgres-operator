#!/usr/bin/env bash
#
# PostgreSQL 内存配置分析脚本
# 
# 用途：分析数据库大小、当前配置，并给出内存优化建议

set -euo pipefail

# 配置
CLUSTER_NAME="ai-postgres"
NAMESPACE="postgres-operator"

# 颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 查找一个可用的 Leader 或 Replica Pod
find_pod() {
    kubectl get pods -n "$NAMESPACE" \
        -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/instance-set=pgha \
        --field-selector=status.phase=Running \
        -o name 2>/dev/null | head -1 | sed 's|pod/||'
}

POD=$(find_pod)

if [ -z "$POD" ]; then
    echo "❌ 找不到运行中的 Pod"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PostgreSQL 内存配置分析"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "使用 Pod: $POD"
echo ""

# 1. 获取 Pod 资源配置
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}📦 Kubernetes Pod 资源配置${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

MEM_LIMIT=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[?(@.name=="database")].resources.limits.memory}')
MEM_REQUEST=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[?(@.name=="database")].resources.requests.memory}')
CPU_LIMIT=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[?(@.name=="database")].resources.limits.cpu}')
CPU_REQUEST=$(kubectl get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[?(@.name=="database")].resources.requests.cpu}')

echo "  内存限制:   $MEM_LIMIT"
echo "  内存请求:   $MEM_REQUEST"
echo "  CPU 限制:   $CPU_LIMIT"
echo "  CPU 请求:   $CPU_REQUEST"
echo ""

# 转换内存为 MB 用于计算
if [[ "$MEM_LIMIT" =~ Gi ]]; then
    MEM_MB=$((${MEM_LIMIT%Gi} * 1024))
elif [[ "$MEM_LIMIT" =~ Mi ]]; then
    MEM_MB=${MEM_LIMIT%Mi}
else
    MEM_MB=16384  # 默认 16GB
fi

# 2. 获取数据库大小信息
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}💾 数据库大小分析${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 获取所有数据库的大小
echo "  📊 所有数据库:"
echo ""
kubectl exec -n "$NAMESPACE" "$POD" -c database -- psql -U postgres -t -A -c "
SELECT 
    datname,
    pg_size_pretty(pg_database_size(datname)) as size,
    pg_database_size(datname) / 1024 / 1024 as size_mb,
    (SELECT count(*) FROM pg_stat_activity WHERE pg_stat_activity.datname = pg_database.datname) as connections
FROM pg_database 
WHERE datistemplate = false
ORDER BY pg_database_size(datname) DESC;
" 2>/dev/null | while IFS='|' read -r dbname dbsize dbsize_mb conns; do
    printf "    %-30s %12s  (%s 连接)\n" "$dbname" "$dbsize" "$conns"
done

echo ""

# 计算总大小
TOTAL_SIZE_INFO=$(kubectl exec -n "$NAMESPACE" "$POD" -c database -- psql -U postgres -t -A -c "
SELECT 
    pg_size_pretty(sum(pg_database_size(datname))::bigint) as total_size,
    sum(pg_database_size(datname))::bigint / 1024 / 1024 as total_size_mb,
    (SELECT count(*) FROM pg_stat_activity WHERE datname NOT IN ('template0', 'template1')) as total_connections,
    (SELECT count(distinct pid) FROM pg_stat_activity WHERE state = 'active' AND datname NOT IN ('template0', 'template1')) as active_queries
FROM pg_database 
WHERE datistemplate = false;
" 2>/dev/null)

TOTAL_SIZE=$(echo "$TOTAL_SIZE_INFO" | cut -d'|' -f1)
DB_SIZE_MB=$(echo "$TOTAL_SIZE_INFO" | cut -d'|' -f2 | awk '{printf "%.0f", $1}')
ACTIVE_CONN=$(echo "$TOTAL_SIZE_INFO" | cut -d'|' -f3)
ACTIVE_QUERIES=$(echo "$TOTAL_SIZE_INFO" | cut -d'|' -f4)

echo -e "  ${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  所有数据库总大小:  $TOTAL_SIZE (${DB_SIZE_MB} MB)"
echo "  当前活跃连接总数:  $ACTIVE_CONN"
echo "  正在执行的查询:    $ACTIVE_QUERIES"
echo ""

# 获取最大的数据库名称用于后续表分析
LARGEST_DB=$(kubectl exec -n "$NAMESPACE" "$POD" -c database -- psql -U postgres -t -A -c "
SELECT datname FROM pg_database 
WHERE datistemplate = false 
  AND datname != 'postgres'
ORDER BY pg_database_size(datname) DESC 
LIMIT 1;
" 2>/dev/null | tr -d '[:space:]')

if [ -n "$LARGEST_DB" ]; then
    echo "  📊 最大数据库 ($LARGEST_DB) 的前 10 个表:"
    kubectl exec -n "$NAMESPACE" "$POD" -c database -- psql -U postgres -d "$LARGEST_DB" -c "
SELECT 
    schemaname || '.' || tablename as table_name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) as table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - pg_relation_size(schemaname||'.'||tablename)) as indexes_size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 10;
" 2>/dev/null || echo "  (无法获取表信息)"
fi
echo ""

# 3. 获取当前 PostgreSQL 内存配置
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}⚙️  当前 PostgreSQL 内存参数${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

PG_CONFIG=$(kubectl exec -n "$NAMESPACE" "$POD" -c database -- psql -U postgres -t -A -c "
SELECT 
    (SELECT setting FROM pg_settings WHERE name = 'shared_buffers') as shared_buffers,
    (SELECT unit FROM pg_settings WHERE name = 'shared_buffers') as sb_unit,
    (SELECT setting FROM pg_settings WHERE name = 'effective_cache_size') as effective_cache_size,
    (SELECT unit FROM pg_settings WHERE name = 'effective_cache_size') as ecs_unit,
    (SELECT setting FROM pg_settings WHERE name = 'work_mem') as work_mem,
    (SELECT unit FROM pg_settings WHERE name = 'work_mem') as wm_unit,
    (SELECT setting FROM pg_settings WHERE name = 'maintenance_work_mem') as maintenance_work_mem,
    (SELECT unit FROM pg_settings WHERE name = 'maintenance_work_mem') as mwm_unit,
    (SELECT setting FROM pg_settings WHERE name = 'max_connections') as max_connections
;" 2>/dev/null)

SHARED_BUFFERS=$(echo "$PG_CONFIG" | cut -d'|' -f1)
SB_UNIT=$(echo "$PG_CONFIG" | cut -d'|' -f2)
EFFECTIVE_CACHE=$(echo "$PG_CONFIG" | cut -d'|' -f3)
ECS_UNIT=$(echo "$PG_CONFIG" | cut -d'|' -f4)
WORK_MEM=$(echo "$PG_CONFIG" | cut -d'|' -f5)
WM_UNIT=$(echo "$PG_CONFIG" | cut -d'|' -f6)
MAINT_WORK_MEM=$(echo "$PG_CONFIG" | cut -d'|' -f7)
MWM_UNIT=$(echo "$PG_CONFIG" | cut -d'|' -f8)
MAX_CONN=$(echo "$PG_CONFIG" | cut -d'|' -f9)

# 计算实际 MB 值
if [ "$SB_UNIT" = "8kB" ]; then
    SHARED_BUFFERS_MB=$((SHARED_BUFFERS * 8 / 1024))
else
    SHARED_BUFFERS_MB=$((SHARED_BUFFERS / 1024))
fi

if [ "$ECS_UNIT" = "8kB" ]; then
    EFFECTIVE_CACHE_MB=$((EFFECTIVE_CACHE * 8 / 1024))
else
    EFFECTIVE_CACHE_MB=$((EFFECTIVE_CACHE / 1024))
fi

WORK_MEM_MB=$((WORK_MEM / 1024))
MAINT_WORK_MEM_MB=$((MAINT_WORK_MEM / 1024))

echo "  shared_buffers:          ${SHARED_BUFFERS_MB} MB (${SHARED_BUFFERS} ${SB_UNIT})"
echo "  effective_cache_size:    ${EFFECTIVE_CACHE_MB} MB (${EFFECTIVE_CACHE} ${ECS_UNIT})"
echo "  work_mem:                ${WORK_MEM_MB} MB (${WORK_MEM} ${WM_UNIT})"
echo "  maintenance_work_mem:    ${MAINT_WORK_MEM_MB} MB (${MAINT_WORK_MEM} ${MWM_UNIT})"
echo "  max_connections:         $MAX_CONN"
echo ""

# 检查 PgBouncer
PGBOUNCER_PODS=$(kubectl get pods -n "$NAMESPACE" -l postgres-operator.crunchydata.com/cluster="$CLUSTER_NAME",postgres-operator.crunchydata.com/role=pgbouncer --no-headers 2>/dev/null | wc -l)
if [ "$PGBOUNCER_PODS" -gt 0 ]; then
    echo "  ✅ 已启用 PgBouncer 连接池 ($PGBOUNCER_PODS 个副本)"
else
    echo "  ⚠️  未启用 PgBouncer 连接池"
fi
echo ""

# 4. 计算使用率
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}📊 资源使用率分析${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SB_PERCENT=$((SHARED_BUFFERS_MB * 100 / MEM_MB))
ECS_PERCENT=$((EFFECTIVE_CACHE_MB * 100 / MEM_MB))

echo "  shared_buffers 占总内存:        ${SB_PERCENT}%"
echo "  effective_cache_size 占总内存:  ${ECS_PERCENT}%"
echo "  数据库大小占 shared_buffers:    $((DB_SIZE_MB * 100 / SHARED_BUFFERS_MB))%"
echo ""

# 5. 生成建议
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}💡 配置优化建议${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 根据数据库大小和内存计算推荐值
RECOMMENDED_SB=$((MEM_MB / 4))  # 25% of total memory
RECOMMENDED_ECS=$((MEM_MB * 3 / 4))  # 75% of total memory

# 根据连接数和有无 PgBouncer 调整 work_mem
if [ "$PGBOUNCER_PODS" -gt 0 ]; then
    # 有连接池，实际并发连接数较少
    ESTIMATED_CONCURRENT=50
else
    # 无连接池，按最大连接数的 10% 估算
    ESTIMATED_CONCURRENT=$((MAX_CONN / 10))
fi

# work_mem 计算：(总内存 - shared_buffers) / 估计并发数 / 2
AVAILABLE_FOR_WORK=$((MEM_MB - RECOMMENDED_SB))
RECOMMENDED_WORK_MEM=$((AVAILABLE_FOR_WORK / ESTIMATED_CONCURRENT / 2))

# 限制范围
if [ $RECOMMENDED_WORK_MEM -lt 16 ]; then
    RECOMMENDED_WORK_MEM=16
elif [ $RECOMMENDED_WORK_MEM -gt 256 ]; then
    RECOMMENDED_WORK_MEM=256
fi

# maintenance_work_mem：数据库大小的 10-20%，最小 256MB，最大 2GB
RECOMMENDED_MAINT_MEM=$((DB_SIZE_MB / 10))
if [ $RECOMMENDED_MAINT_MEM -lt 256 ]; then
    RECOMMENDED_MAINT_MEM=256
elif [ $RECOMMENDED_MAINT_MEM -gt 2048 ]; then
    RECOMMENDED_MAINT_MEM=2048
fi

echo -e "${CYAN}基于当前分析：${NC}"
echo "  • 分配内存: ${MEM_MB} MB (${MEM_LIMIT})"
echo "  • 数据库总大小: ${DB_SIZE_MB} MB ($(echo "scale=2; $DB_SIZE_MB/1024" | bc)GB)"
echo "  • 数据库数量: $(kubectl exec -n "$NAMESPACE" "$POD" -c database -- psql -U postgres -t -c "SELECT count(*) FROM pg_database WHERE datistemplate = false;" 2>/dev/null | tr -d '[:space:]') 个"
echo "  • 最大连接数: $MAX_CONN"
if [ "$PGBOUNCER_PODS" -gt 0 ]; then
    echo "  • 有 PgBouncer 连接池，估计实际并发: ~${ESTIMATED_CONCURRENT}"
fi
echo ""

# 判断是否需要调整内存
if [ $DB_SIZE_MB -lt 100 ]; then
    # 数据库很小
    if [ $MEM_MB -gt 8192 ]; then
        echo -e "${YELLOW}⚠️  数据库总大小较小 (${DB_SIZE_MB}MB)，当前分配的 ${MEM_LIMIT} 内存较多${NC}"
        echo ""
        echo -e "${GREEN}方案 A: 优化内存分配（节省资源）${NC}"
        echo "  建议降低到: 8Gi"
        echo ""
        echo "  config:"
        echo "    parameters:"
        echo "      max_connections: $MAX_CONN"
        echo "      shared_buffers: \"2GB\""
        echo "      effective_cache_size: \"6GB\""
        echo "      work_mem: \"32MB\""
        echo "      maintenance_work_mem: \"512MB\""
        echo ""
    fi
elif [ $DB_SIZE_MB -ge 100 ] && [ $DB_SIZE_MB -lt 1024 ]; then
    # 数据库中等大小 (100MB-1GB)
    if [ $MEM_MB -lt 8192 ]; then
        echo -e "${YELLOW}⚠️  数据库总大小 ${DB_SIZE_MB}MB，当前分配的 ${MEM_LIMIT} 内存可能不足${NC}"
        echo ""
        echo -e "${GREEN}方案 A: 增加内存分配（推荐）${NC}"
        echo "  建议增加到: 8-16Gi"
        echo ""
    fi
elif [ $DB_SIZE_MB -ge 1024 ] && [ $DB_SIZE_MB -lt 5120 ]; then
    # 数据库较大 (1GB-5GB)
    if [ $MEM_MB -lt 16384 ]; then
        echo -e "${YELLOW}⚠️  数据库总大小 ${DB_SIZE_MB}MB ($(echo "scale=1; $DB_SIZE_MB/1024" | bc)GB)，当前分配的 ${MEM_LIMIT} 可能不够${NC}"
        echo ""
        echo -e "${GREEN}方案 A: 增加内存分配（推荐）${NC}"
        echo "  建议: 16-32Gi"
        echo ""
        echo "  config:"
        echo "    parameters:"
        echo "      max_connections: $MAX_CONN"
        echo "      shared_buffers: \"4GB\""
        echo "      effective_cache_size: \"12GB\""
        echo "      work_mem: \"64MB\""
        echo "      maintenance_work_mem: \"1GB\""
        echo ""
    else
        echo -e "${GREEN}✅ 当前 ${MEM_LIMIT} 内存分配合理（数据库 $(echo "scale=1; $DB_SIZE_MB/1024" | bc)GB）${NC}"
        echo ""
    fi
elif [ $DB_SIZE_MB -ge 5120 ]; then
    # 数据库很大 (>5GB)
    if [ $MEM_MB -lt 32768 ]; then
        echo -e "${YELLOW}⚠️  数据库很大 ${DB_SIZE_MB}MB ($(echo "scale=1; $DB_SIZE_MB/1024" | bc)GB)，建议增加内存${NC}"
        echo ""
        echo -e "${GREEN}方案 A: 增加内存分配（推荐）${NC}"
        echo "  建议: 32-64Gi"
        echo ""
    fi
fi

echo -e "${GREEN}方案 B: 保持当前内存，优化 PostgreSQL 参数（推荐）${NC}"
echo ""
echo "  config:"
echo "    parameters:"
echo "      max_connections: $MAX_CONN"
echo "      shared_buffers: \"${RECOMMENDED_SB}MB\"      # 当前: ${SHARED_BUFFERS_MB}MB (${SB_PERCENT}%)"
echo "      effective_cache_size: \"${RECOMMENDED_ECS}MB\"  # 当前: ${EFFECTIVE_CACHE_MB}MB (${ECS_PERCENT}%)"
echo "      work_mem: \"${RECOMMENDED_WORK_MEM}MB\"          # 当前: ${WORK_MEM_MB}MB"
echo "      maintenance_work_mem: \"${RECOMMENDED_MAINT_MEM}MB\"  # 当前: ${MAINT_WORK_MEM_MB}MB"
echo "      "
echo "      # 额外优化参数"
echo "      random_page_cost: 1.1              # SSD 优化"
echo "      effective_io_concurrency: 200      # SSD 并发"
echo "      wal_buffers: \"16MB\""
echo "      checkpoint_completion_target: 0.9"
echo ""

# 预期增长建议
echo -e "${CYAN}预期增长场景：${NC}"

DB_SIZE_GB=$(echo "scale=2; $DB_SIZE_MB/1024" | bc)

if (( $(echo "$DB_SIZE_GB < 0.5" | bc -l) )); then
    echo "  • 当前数据: ${DB_SIZE_GB}GB"
    echo "  • 增长到 2GB，建议内存: 8-16Gi"
    echo "  • 增长到 5GB，建议内存: 16-32Gi"
elif (( $(echo "$DB_SIZE_GB < 2" | bc -l) )); then
    echo "  • 当前数据: ${DB_SIZE_GB}GB"
    echo "  • 增长到 5GB，建议内存: 16-32Gi"
    echo "  • 增长到 10GB，建议内存: 32-64Gi"
elif (( $(echo "$DB_SIZE_GB < 5" | bc -l) )); then
    echo "  • 当前数据: ${DB_SIZE_GB}GB"
    echo "  • 增长到 10GB，建议内存: 32-64Gi"
    echo "  • 增长到 20GB，建议内存: 64-128Gi"
else
    echo "  • 当前数据: ${DB_SIZE_GB}GB"
    echo "  • 增长到 2 倍，建议内存: $((MEM_MB * 2 / 1024))Gi"
    echo "  • 持续监控数据增长趋势"
fi
echo ""

# 6. 性能指标
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}📈 性能指标（缓存命中率）${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kubectl exec -n "$NAMESPACE" "$POD" -c database -- psql -U postgres -c "
SELECT 
    'Buffer Cache Hit Ratio' as metric,
    round(100.0 * sum(blks_hit) / nullif(sum(blks_hit) + sum(blks_read), 0), 2) || '%' as value,
    '(所有数据库)' as scope
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
UNION ALL
SELECT 
    'Committed Transactions' as metric,
    sum(xact_commit)::text as value,
    '(所有数据库)' as scope
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1');
" 2>/dev/null || echo "  (无法获取性能指标)"

echo ""
echo "  说明:"
echo "  • Buffer Cache Hit Ratio > 95%: 内存充足"
echo "  • Buffer Cache Hit Ratio < 90%: 建议增加 shared_buffers"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  分析完成"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "💾 要应用推荐配置，请编辑: custom/ai-server-adv-db/ha-postgres.yaml"
echo "🚀 然后运行: kubectl apply -k custom/ai-server-adv-db/"
echo ""

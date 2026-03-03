# PostgreSQL HA 集群故障排查与修复指南

## 问题概述

**时间**: 2026-03-03  
**集群**: ai-postgres (3副本高可用集群)  
**影响**: Pod `ai-postgres-pgha-vw55-0` 无法正常启动，集群出现 Leader 选举失败

## 故障现象

### 1. Pod 状态异常
- Pod 状态: `ContainersNotReady` / `Terminating`
- database 容器处于 `ContainerNotReady` 等待状态
- 重启次数: 0 (无限循环创建失败)

### 2. 错误日志特征

```log
# Kubernetes API 超时错误
urllib3.exceptions.ReadTimeoutError: HTTPSConnectionPool(host='10.43.0.1', port=443): Read timed out.
patroni.dcs.kubernetes.K8sException: POST /api/v1/namespaces/postgres-operator/services request failed

# 数据目录损坏
2026-03-03 07:07:20,758 INFO: data dir for the cluster is not empty, but system ID is invalid; consider doing reinitialize

# 无 Leader，无法引导
2026-03-03 07:13:02,620 INFO: trying to bootstrap (without leader)
2026-03-03 07:13:12,054 INFO: not healthy enough for leader race
2026-03-03 07:13:12,375 INFO: bootstrap (without leader) in progress
```

### 3. Patroni 集群状态
```
+ Cluster: ai-postgres-ha (7544951886836486230)
+-------------------------+---------+--------------------+-----+-----------+
| Member                  | Role    | State              |  TL | Lag in MB |
+-------------------------+---------+--------------------+-----+-----------+
| ai-postgres-pgha-74p5-0 | Replica | in archive recovery| 211 |        31 |
| ai-postgres-pgha-vw55-0 | Replica | creating replica   |     |   unknown |
| ai-postgres-pgha-xz5g-0 | Replica | in archive recovery| 211 |        31 |
+-------------------------+---------+--------------------+-----+-----------+
```

**关键问题**: 没有 Leader！所有节点都是 Replica。

## 根本原因分析

### 主要原因
1. **Leader 选举失败**: Kubernetes API 通信问题导致 Patroni 无法完成 Leader 选举
2. **数据目录损坏**: `ai-postgres-pgha-vw55-0` 的 PVC 中存在无效的 System ID
3. **Split-Brain 状态**: 所有节点都认为应该有 Leader，但都不愿意成为 Leader

### 触发因素
- Pod 异常终止后残留损坏的数据
- Kubernetes API 服务器响应慢（可能是资源压力）
- Patroni 无法创建 config service 导致协调失败

## 解决步骤

### 第一阶段：修复 Leader 选举

#### 步骤 1: 诊断集群状态
```bash
# 检查所有 PostgreSQL 实例
kubectl get pods -n postgres-operator -l postgres-operator.crunchydata.com/cluster=ai-postgres -o wide

# 检查 Patroni 集群拓扑
kubectl exec -n postgres-operator ai-postgres-pgha-74p5-0 -c database -- patronictl list
```

**发现**: 3 个节点都是 Replica，无 Leader。

#### 步骤 2: 重启 Operator 触发重新选举（关键步骤）
```bash
# 重启 PostgreSQL Operator
kubectl rollout restart deployment pgo -n postgres-operator

# 等待 15-30 秒
sleep 15

# 验证 Leader 选举结果
kubectl exec -n postgres-operator ai-postgres-pgha-74p5-0 -c database -- patronictl list
```

**结果**: 
```
| ai-postgres-pgha-74p5-0 | Leader  | running          | 212 |           |
| ai-postgres-pgha-vw55-0 | Replica | creating replica |     |   unknown |
| ai-postgres-pgha-xz5g-0 | Replica | streaming        | 212 |         0 |
```

✅ **成功选举 Leader！**

### 第二阶段：修复损坏的副本

#### 问题：数据目录损坏
`ai-postgres-pgha-vw55-0` 持续显示 `creating replica` / `stopped` 状态，日志显示：
```
INFO: data dir for the cluster is not empty, but system ID is invalid; consider doing reinitialize
```

#### 步骤 3: 临时缩减副本数（避免 StatefulSet 立即重建 Pod）

**关键技巧**: 删除 Pod 后 StatefulSet 会立即重建，必须先缩减副本数！

```bash
# 方法 A: 使用 kubectl patch（推荐）
kubectl patch postgrescluster ai-postgres -n postgres-operator \
  --type='json' -p='[{"op": "replace", "path": "/spec/instances/0/replicas", "value": 2}]'

# 或方法 B: 直接编辑
kubectl edit postgrescluster ai-postgres -n postgres-operator
# 将 spec.instances[0].replicas 从 3 改为 2
```

#### 步骤 4: 等待 Pod 自动删除
```bash
# 监控 Pod 删除（通常 30-60 秒）
kubectl get pods -n postgres-operator -w | grep vw55
```

#### 步骤 5: 删除损坏的 PVC
```bash
# 确认 Pod 已删除
kubectl get pod ai-postgres-pgha-vw55-0 -n postgres-operator
# 应该返回 "NotFound"

# 删除孤立的 PVC
kubectl delete pvc ai-postgres-pgha-vw55-pgdata -n postgres-operator
```

#### 步骤 6: 恢复副本数
```bash
# 恢复到 3 个副本
kubectl patch postgrescluster ai-postgres -n postgres-operator \
  --type='json' -p='[{"op": "replace", "path": "/spec/instances/0/replicas", "value": 3}]'
```

#### 步骤 7: 监控新 Pod 启动
```bash
# 监控 Pod 创建和初始化
kubectl get pods -n postgres-operator | grep vw55

# 查看 PVC 创建
kubectl get pvc -n postgres-operator | grep vw55

# 检查 Patroni 状态
kubectl exec -n postgres-operator ai-postgres-pgha-74p5-0 -c database -- patronictl list
```

**预期过程**:
1. 新 PVC 创建: `Pending` → `Bound` (10-30 秒)
2. Pod 初始化: `Pending` → `Init:0/2` → `Init:1/2` → `Init:2/2` (1-2 分钟)
3. 容器启动: `0/4` → `3/4` → `4/4` (数据同步时间取决于数据库大小)
4. Patroni 状态: `creating replica` → `streaming` (5-30 分钟)

## 验证修复成功

### 检查集群健康状态
```bash
# 1. 所有 Pod 应该 Ready
kubectl get pods -n postgres-operator -l postgres-operator.crunchydata.com/cluster=ai-postgres
# 期望: 所有 Pod 都是 4/4 Running

# 2. 集群应该有 1 个 Leader + 2 个 Replica streaming
kubectl exec -n postgres-operator ai-postgres-pgha-74p5-0 -c database -- patronictl list

# 3. 检查复制延迟（应该为 0 或很小）
kubectl exec -n postgres-operator ai-postgres-pgha-74p5-0 -c database -- \
  patronictl list | grep "Lag in MB"

# 4. 检查 PostgresCluster 状态
kubectl get postgrescluster ai-postgres -n postgres-operator -o yaml | grep -A 10 "status:"
```

### 预期输出
```
+ Cluster: ai-postgres-ha (7544951886836486230)
+-------------------------+---------+----------+-----+-----------+
| Member                  | Role    | State    |  TL | Lag in MB |
+-------------------------+---------+----------+-----+-----------+
| ai-postgres-pgha-74p5-0 | Leader  | running  | 212 |           |
| ai-postgres-pgha-vw55-0 | Replica | streaming| 212 |         0 |
| ai-postgres-pgha-xz5g-0 | Replica | streaming| 212 |         0 |
+-------------------------+---------+----------+-----+-----------+
```

## 常见问题与解决方案

### Q1: 为什么直接删除 Pod + PVC 不行？

**A**: StatefulSet 会在检测到 Pod 被删除后立即创建同名 Pod，新 Pod 会立即挂载同名 PVC，导致：
- PVC 无法删除（被新 Pod 占用）
- 新 Pod 继续使用损坏的数据
- 形成无限循环

**解决**: 必须先缩减副本数，让 Operator 优雅地删除 Pod，然后再删除 PVC。

### Q2: 为什么重启 Operator 能解决 Leader 选举问题？

**A**: Operator 维护整个集群的期望状态，重启后会：
- 重新读取 PostgresCluster 资源
- 检查实际状态与期望状态的差异
- 触发协调逻辑，包括 Patroni Leader 选举
- 清理可能存在的状态不一致

### Q3: 如果只有 1 个副本健康怎么办？

**A**: **绝对不要删除健康副本的 PVC！** 应该：
1. 确保至少有 2 个健康副本
2. 仅删除损坏副本的 PVC
3. 如果只有 1 个健康副本，优先修复其他副本，而非删除数据

### Q4: 数据会丢失吗？

**A**: 不会，因为：
- Leader 和至少 1 个健康 Replica 保存完整数据
- 删除的只是损坏副本的 PVC
- 新副本会从 Leader 完整同步数据（pg_basebackup 或 pgBackRest）

## 灾难恢复：从备份完全重建集群

### 场景：整个集群完全损坏

当遇到以下情况时，需要从备份完全重建集群：
- 所有 3 个副本的 PVC 都损坏
- 没有任何健康的 Pod 可以作为数据源
- 数据库文件系统损坏且无法修复
- 需要回滚到历史某个时间点

### 前提条件检查

#### 1. 确认备份可用
```bash
# 检查备份 Pod 状态
kubectl get pod -n postgres-operator | grep repo-host

# 查看可用的备份
kubectl exec -n postgres-operator ai-postgres-repo-host-0 -- \
  pgbackrest --stanza=db info

# 应该看到类似输出：
# stanza: db
#     status: ok
#     
#     full backup: 20250901-030749F
#         timestamp start/stop: 2025-09-01 03:07:49+00 / 2025-09-01 03:09:44+00
#         database size: 29.6MB
#     
#     incr backup: 20250901-030749F_20251229-034213I
#         timestamp start/stop: 2025-12-29 03:42:13+00 / 2025-12-29 03:44:39+00
#         database size: 1.4GB
```

#### 2. 确认备份存储完好
```bash
# 检查备份 PVC
kubectl get pvc -n postgres-operator | grep repo

# 检查备份存储空间
kubectl exec -n postgres-operator ai-postgres-repo-host-0 -- df -h /pgbackrest
```

### 恢复方法 A：在线恢复（推荐）

**适用场景**: 需要保留集群配置，只恢复数据

#### 步骤 1: 删除所有实例 Pod 和数据 PVC
```bash
# 缩减副本数到 0（停止所有实例）
kubectl patch postgrescluster ai-postgres -n postgres-operator \
  --type='json' -p='[{"op": "replace", "path": "/spec/instances/0/replicas", "value": 0}]'

# 等待所有实例 Pod 被删除
kubectl get pods -n postgres-operator -l postgres-operator.crunchydata.com/instance-set=pgha -w

# 删除所有数据 PVC（保留备份 PVC！）
kubectl get pvc -n postgres-operator | grep pgha.*pgdata | awk '{print $1}' | \
  xargs -I {} kubectl delete pvc {} -n postgres-operator

# 验证 PVC 已删除
kubectl get pvc -n postgres-operator | grep pgdata
# 应该没有输出

# ⚠️ 重要：不要删除 repo PVC！
# ai-postgres-pgbackrest-repo 必须保留
```

#### 步骤 2: 配置集群从备份恢复

编辑 `ha-postgres.yaml` 添加恢复配置：

```yaml
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: ai-postgres
spec:
  postgresVersion: 17
  
  # 添加恢复配置
  dataSource:
    pgbackrest:
      stanza: db
      configuration:
        - secret:
            name: ai-postgres-pgbackrest-secret
      global:
        repo1-path: /pgbackrest/repo1
      repo:
        name: repo1
        # 恢复到最新备份
        # options:
        #   - --type=time
        #   - --target="2026-03-03 07:00:00"  # 可选：恢复到指定时间点
  
  # 其他配置保持不变
  users:
    - name: longred
      databases:
        - ai-server-adv
      options: "SUPERUSER"
  
  instances:
    - name: pgha
      replicas: 3
      # ... 其余配置
```

#### 步骤 3: 应用配置并启动恢复
```bash
# 应用更新的配置（触发恢复）
kubectl apply -k custom/ai-server-adv-db/

# 监控恢复进度
kubectl get pods -n postgres-operator -l postgres-operator.crunchydata.com/cluster=ai-postgres -w

# 查看恢复日志
kubectl logs -n postgres-operator ai-postgres-pgha-<xxx>-0 -c database -f
```

**恢复过程日志示例**：
```log
INFO: restore command begin
INFO: using stanza: db
INFO: restore backup set 20251229-034213I
INFO: write <DATA_DIRECTORY>/backup_label
INFO: write <DATA_DIRECTORY>/postgresql.auto.conf
INFO: restore file <DATA_DIRECTORY>/global/pg_control
...
INFO: restore file <DATA_DIRECTORY>/base/...
INFO: restore completed successfully
INFO: starting PostgreSQL
```

#### 步骤 4: 验证恢复成功
```bash
# 等待所有 Pod Ready（可能需要 10-60 分钟，取决于数据库大小）
kubectl get pods -n postgres-operator -l postgres-operator.crunchydata.com/instance-set=pgha

# 检查 Patroni 集群状态
kubectl exec -n postgres-operator ai-postgres-pgha-<xxx>-0 -c database -- patronictl list

# 验证数据库可连接
kubectl exec -n postgres-operator ai-postgres-pgha-<xxx>-0 -c database -- \
  psql -U postgres -c "SELECT version();"

# 检查数据是否完整
kubectl exec -n postgres-operator ai-postgres-pgha-<xxx>-0 -c database -- \
  psql -U longred -d ai-server-adv -c "\dt"  # 列出所有表
```

#### 步骤 5: 移除恢复配置（重要！）
```bash
# 恢复完成后，从 ha-postgres.yaml 中删除 dataSource 配置
# 否则集群重启时会重复执行恢复！

# 编辑配置文件，移除 dataSource 部分
# 然后重新应用
kubectl apply -k custom/ai-server-adv-db/
```

### 恢复方法 B：完全重建集群

**适用场景**: 需要全新环境，或者集群资源损坏严重

#### 步骤 1: 备份当前配置和备份数据
```bash
# 导出 PostgresCluster 配置
kubectl get postgrescluster ai-postgres -n postgres-operator -o yaml > ai-postgres-backup.yaml

# 如果备份 PVC 也可能受影响，先导出备份数据
kubectl exec -n postgres-operator ai-postgres-repo-host-0 -- \
  tar czf /tmp/pgbackrest-backup.tar.gz /pgbackrest/repo1

# 复制到本地
kubectl cp postgres-operator/ai-postgres-repo-host-0:/tmp/pgbackrest-backup.tar.gz \
  ./pgbackrest-backup.tar.gz
```

#### 步骤 2: 完全删除集群
```bash
# 删除 PostgresCluster（会删除所有关联资源）
kubectl delete -k custom/ai-server-adv-db/

# 等待所有资源清理完成
kubectl get all,pvc -n postgres-operator | grep ai-postgres
# 应该没有输出（除了 repo PVC 如果配置为保留）

# 如果 PVC 卡住，强制删除
kubectl patch pvc <pvc-name> -n postgres-operator \
  -p '{"metadata":{"finalizers":null}}'
```

#### 步骤 3: 重建集群（使用 dataSource）
```bash
# 使用包含 dataSource 配置的 yaml 重新创建集群
kubectl apply -k custom/ai-server-adv-db/

# 集群会自动从备份恢复
```

### 恢复到特定时间点 (Point-in-Time Recovery)

如果需要恢复到历史某个时刻（例如：误删除数据前）：

```yaml
spec:
  dataSource:
    pgbackrest:
      stanza: db
      configuration:
        - secret:
            name: ai-postgres-pgbackrest-secret
      global:
        repo1-path: /pgbackrest/repo1
      repo:
        name: repo1
        options:
          - --type=time
          - --target="2026-03-02 15:30:00"  # 恢复到此时间点
          # 或使用 LSN
          # - --type=lsn
          # - --target="0/3000000"
```

### 恢复时间估算

| 数据库大小 | Full Backup 恢复时间 | Incremental + WAL 重放时间 |
|-----------|---------------------|--------------------------|
| < 10 GB   | 5-10 分钟             | +2-5 分钟                 |
| 10-100 GB | 15-30 分钟            | +10-30 分钟               |
| 100-500 GB| 1-2 小时              | +30-60 分钟               |
| > 500 GB  | 2-5 小时              | +1-3 小时                 |

*实际时间取决于磁盘 I/O 性能*

### 恢复后验证清单

- [ ] 所有 Pod 状态为 Running (4/4)
- [ ] Patroni 集群有 1 个 Leader，2 个 Replica streaming
- [ ] 数据库可以正常连接
- [ ] 关键表数据完整性检查
- [ ] 应用连接测试通过
- [ ] 移除 `dataSource` 配置防止重复恢复
- [ ] 验证新备份可以正常创建

### 常见恢复问题

#### Q1: 恢复失败 "backup set not found"
```bash
# 检查备份 stanza 是否正确
kubectl exec -n postgres-operator ai-postgres-repo-host-0 -- \
  pgbackrest --stanza=db info

# 检查备份文件是否存在
kubectl exec -n postgres-operator ai-postgres-repo-host-0 -- \
  ls -lh /pgbackrest/repo1/backup/db/
```

#### Q2: 恢复后数据不完整
- 检查是否恢复到了正确的时间点
- 查看 WAL 归档是否完整
- 验证增量备份链是否完整

#### Q3: 恢复速度很慢
- 检查存储 IOPS 性能
- 考虑使用并行恢复（pgBackRest 支持）
- 验证网络带宽（如果备份在远程存储）

## 预防措施

### 1. 监控告警
```yaml
# 建议监控指标
- Patroni Leader 状态（必须始终有 1 个 Leader）
- Pod Ready 状态
- 复制延迟 (Lag in MB < 100)
- PVC 使用率 (< 80%)
- pgBackRest 备份成功率（应该 100%）
- 最后一次成功备份时间（< 24 小时）
```

### 2. 资源保障
```yaml
# 确保充足的资源配置
instances:
  - resources:
      limits:
        cpu: "4"
        memory: "16Gi"
      requests:
        cpu: "1"      # 避免 CPU throttling
        memory: "16Gi" # 避免 OOM

# 备份存储也需要充足空间
backups:
  pgbackrest:
    repos:
      - name: repo1
        volume:
          volumeClaimSpec:
            resources:
              requests:
                storage: 200Gi  # 至少是数据库大小的 2-3 倍
```

### 3. 定期备份与测试
```bash
# 验证 pgBackRest 备份正常
kubectl exec -n postgres-operator ai-postgres-repo-host-0 -- \
  pgbackrest --stanza=db info

# 定期测试恢复流程（建议每月一次）
# 在非生产环境测试完整恢复流程

# 配置自动备份（在 PostgresCluster 中）
spec:
  backups:
    pgbackrest:
      repos:
        - name: repo1
          schedules:
            full: "0 1 * * 0"       # 每周日 1:00 AM 全量备份
            incremental: "0 1 * * 1-6"  # 每天 1:00 AM 增量备份
```

### 4. 健康检查
```bash
# 定期检查集群健康（可以加入 cron）
kubectl exec -n postgres-operator <any-pod> -c database -- patronictl list

# 检查备份历史
kubectl exec -n postgres-operator ai-postgres-repo-host-0 -- \
  pgbackrest --stanza=db info --output=json | jq '.[] | .backup'
```

### 5. 网络稳定性
- 确保 Pod 到 Kubernetes API Server 的网络稳定
- 监控 API Server 响应时间
- 考虑增加 Patroni 超时配置（如果环境压力大）

### 6. 备份策略建议
```yaml
# 推荐的备份策略
- 全量备份: 每周一次（周末低峰期）
- 增量备份: 每天一次
- WAL 归档: 实时（自动）
- 备份保留: 
  - 全量备份保留 4 周
  - 增量备份保留 2 周
  - WAL 保留对应备份周期

# 在 PostgresCluster 中配置
spec:
  backups:
    pgbackrest:
      global:
        repo1-retention-full: "4"
        repo1-retention-diff: "2"
      repos:
        - name: repo1
          schedules:
            full: "0 2 * * 0"
            incremental: "0 2 * * 1-6"
```

## 总结

### 关键经验
1. ✅ **重启 Operator 是首选方案** - 安全且自动化
2. ✅ **缩减副本数再删除 PVC** - 避免 StatefulSet 立即重建
3. ✅ **确保至少 2 个健康副本** - 数据安全第一
4. ✅ **定期验证备份可用性** - 灾难恢复的保险
5. ⚠️ **不要惊慌删除 PVC** - 先诊断，后操作
6. ⚠️ **恢复后必须移除 dataSource** - 防止重复恢复

### 故障分级与处理策略

| 故障级别 | 场景描述 | 处理方案 | 预计恢复时间 |
|---------|---------|---------|------------|
| **L1 轻微** | 单个副本 Pod 异常 | 重启 Pod 或删除 PVC | 5-15 分钟 |
| **L2 中等** | 无 Leader 选举 | 重启 Operator | 1-5 分钟 |
| **L3 严重** | 多个副本损坏 | 缩减副本 + 重建 | 10-60 分钟 |
| **L4 灾难** | 全集群数据损坏 | 从备份恢复 | 1-5 小时 |

### 操作优先级

**常规故障（有健康副本）**:
```
诊断 → 重启 Operator → 验证 Leader 选举 → 
缩减副本 → 删除损坏 PVC → 恢复副本 → 验证同步
```

**灾难恢复（无健康副本）**:
```
验证备份可用 → 缩减副本到 0 → 删除所有数据 PVC → 
配置 dataSource → 应用配置触发恢复 → 验证数据 → 移除 dataSource
```

### 时间参考
- Operator 重启触发选举: **15-30 秒**
- Pod 初始化完成: **1-2 分钟**
- 副本数据同步: **5-60 分钟**（从健康副本）
- 从备份恢复: **10 分钟 - 5 小时**（取决于数据库大小和备份类型）

## 相关资源

- CrunchyData PostgreSQL Operator 文档: https://access.crunchydata.com/documentation/postgres-operator/
- Patroni 文档: https://patroni.readthedocs.io/
- 集群配置文件: `custom/ai-server-adv-db/ha-postgres.yaml`

---

**文档创建时间**: 2026-03-03  
**最后更新**: 2026-03-03  
**版本**: 1.0

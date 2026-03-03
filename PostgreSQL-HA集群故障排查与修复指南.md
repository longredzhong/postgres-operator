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

## 预防措施

### 1. 监控告警
```yaml
# 建议监控指标
- Patroni Leader 状态（必须始终有 1 个 Leader）
- Pod Ready 状态
- 复制延迟 (Lag in MB < 100)
- PVC 使用率 (< 80%)
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
```

### 3. 定期备份
```bash
# 验证 pgBackRest 备份正常
kubectl exec -n postgres-operator ai-postgres-repo-host-0 -- \
  pgbackrest --stanza=db info

# 定期测试恢复流程
```

### 4. 健康检查
```bash
# 定期检查集群健康（可以加入 cron）
kubectl exec -n postgres-operator <any-pod> -c database -- patronictl list
```

### 5. 网络稳定性
- 确保 Pod 到 Kubernetes API Server 的网络稳定
- 监控 API Server 响应时间
- 考虑增加 Patroni 超时配置（如果环境压力大）

## 总结

### 关键经验
1. ✅ **重启 Operator 是首选方案** - 安全且自动化
2. ✅ **缩减副本数再删除 PVC** - 避免 StatefulSet 立即重建
3. ✅ **确保至少 2 个健康副本** - 数据安全第一
4. ⚠️ **不要惊慌删除 PVC** - 先诊断，后操作

### 操作优先级
```
诊断 → 重启 Operator → 验证 Leader 选举 → 
缩减副本 → 删除损坏 PVC → 恢复副本 → 验证同步
```

### 时间参考
- Operator 重启触发选举: **15-30 秒**
- Pod 初始化完成: **1-2 分钟**
- 数据同步完成: **5-60 分钟**（取决于数据库大小）

## 相关资源

- CrunchyData PostgreSQL Operator 文档: https://access.crunchydata.com/documentation/postgres-operator/
- Patroni 文档: https://patroni.readthedocs.io/
- 集群配置文件: `custom/ai-server-adv-db/ha-postgres.yaml`

---

**文档创建时间**: 2026-03-03  
**最后更新**: 2026-03-03  
**版本**: 1.0

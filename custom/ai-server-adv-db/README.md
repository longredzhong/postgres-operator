# PostgreSQL HA 集群配置目录

此目录包含 PostgreSQL 高可用集群的配置文件和运维工具。

## 文件说明

### 配置文件

#### `ha-postgres.yaml`
**主要集群配置文件** - 定义 PostgreSQL 高可用集群的完整配置

- **用途**: 生产环境的 3 副本 HA 集群
- **特性**: 
  - PostgreSQL 17
  - 3 个实例副本，支持高可用
  - PgBouncer 连接池（2 个副本）
  - pgBackRest 自动备份
  - Pod 反亲和性调度

**部署**:
```bash
kubectl apply -k custom/ai-server-adv-db/
```

#### `disaster-recovery-example.yaml`
**灾难恢复配置示例** - 包含 dataSource 配置的完整示例

- **用途**: 当整个集群数据损坏时从备份恢复
- **包含**: 
  - 最新备份恢复配置
  - 时间点恢复 (PITR) 配置示例
  - LSN/XID 恢复配置示例

**⚠️ 警告**: 此配置会覆盖现有数据！使用前请仔细阅读注释。

### 运维脚本

#### `disaster-recovery.sh`
**自动化灾难恢复脚本** - 一键执行完整的灾难恢复流程

**功能**:
- ✅ 自动检查前提条件和备份可用性
- ✅ 交互式确认（防止误操作）
- ✅ 自动缩减副本、删除 PVC、恢复数据
- ✅ 支持时间点恢复 (PITR)
- ✅ Dry-run 模式预览操作

**基本用法**:
```bash
# 交互式恢复到最新备份
./disaster-recovery.sh

# 恢复到指定时间点
./disaster-recovery.sh --backup-time "2026-03-02 15:30:00"

# 预览将要执行的操作（不实际执行）
./disaster-recovery.sh --dry-run

# 查看所有选项
./disaster-recovery.sh --help
```

**选项**:
- `--cluster-name NAME` - 集群名称（默认: ai-postgres）
- `--namespace NAMESPACE` - 命名空间（默认: postgres-operator）
- `--replicas N` - 目标副本数（默认: 3）
- `--backup-time "TIME"` - 恢复到指定时间点
- `--dry-run` - 仅预览，不执行
- `--skip-confirmation` - 跳过确认（危险！）

#### `health-check.sh`
**集群健康检查脚本** - 快速诊断集群和备份状态

**功能**:
- ✅ Pod 状态检查
- ✅ Patroni 集群拓扑检查
- ✅ 备份可用性验证
- ✅ PVC 存储状态
- ✅ 数据库连接测试
- ✅ 彩色输出，易于识别问题

**基本用法**:
```bash
# 快速健康检查
./health-check.sh

# 显示详细信息
./health-check.sh --detailed

# 检查其他集群
./health-check.sh --cluster-name other-cluster --namespace other-ns
```

**输出示例**:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PostgreSQL HA 集群健康检查
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Pod 状态检查
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ 所有 Pod 正常 (3/3)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Patroni 集群状态
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Leader: 1
ℹ️  Replica: 2
✅ 所有 Replica 正在同步

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  备份状态检查
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ 备份 Pod 运行正常
✅ 备份 Stanza 状态正常
✅ 全量备份: 1 个
ℹ️  增量备份: 2 个
```

### `kustomization.yaml`
**Kustomize 配置** - 用于 kubectl apply -k 部署

## 使用场景

### 场景 1: 日常运维检查
```bash
# 每天早上或定期检查集群健康
./health-check.sh --detailed
```

### 场景 2: 单个副本故障
参考主文档 `PostgreSQL-HA集群故障排查与修复指南.md` 中的"常规故障处理"章节

### 场景 3: 完全集群损坏（灾难恢复）
```bash
# 1. 检查备份可用性
./health-check.sh

# 2. 预览恢复操作
./disaster-recovery.sh --dry-run

# 3. 执行恢复
./disaster-recovery.sh

# 4. 恢复完成后，删除 dataSource 配置
kubectl patch postgrescluster ai-postgres -n postgres-operator \
  --type=json -p='[{"op": "remove", "path": "/spec/dataSource"}]'
```

### 场景 4: 恢复到历史时间点
```bash
# 例如：恢复到数据被误删除之前
./disaster-recovery.sh --backup-time "2026-03-02 15:30:00"
```

## 重要提醒

### ⚠️ 灾难恢复注意事项

1. **备份验证**: 定期使用 `health-check.sh` 验证备份可用
2. **测试恢复**: 建议每月在非生产环境测试一次完整恢复流程
3. **数据丢失**: 从备份恢复会丢失备份时间点之后的数据（除非有 WAL 归档）
4. **移除 dataSource**: 恢复完成后**必须**删除 dataSource 配置！

### 🔒 安全建议

1. **权限控制**: 限制 disaster-recovery.sh 的执行权限
2. **双重确认**: 脚本默认需要两次确认，不要轻易使用 `--skip-confirmation`
3. **备份副本**: 关键操作前，考虑先备份 pgBackRest repo
4. **操作记录**: 重要操作应记录日志，便于审计

## 相关文档

- 📖 [PostgreSQL-HA集群故障排查与修复指南.md](../../PostgreSQL-HA集群故障排查与修复指南.md) - 完整故障排查指南
- 📖 [CrunchyData Postgres Operator 官方文档](https://access.crunchydata.com/documentation/postgres-operator/)
- 📖 [Patroni 文档](https://patroni.readthedocs.io/)
- 📖 [pgBackRest 文档](https://pgbackrest.org/)

## 快速参考

### 常用命令

```bash
# 查看集群状态
kubectl get postgrescluster ai-postgres -n postgres-operator

# 查看所有 Pod
kubectl get pods -n postgres-operator -l postgres-operator.crunchydata.com/cluster=ai-postgres

# 查看 Patroni 集群
kubectl exec -n postgres-operator ai-postgres-pgha-<xxx>-0 -c database -- patronictl list

# 查看备份信息
kubectl exec -n postgres-operator ai-postgres-repo-host-0 -- pgbackrest --stanza=db info

# 手动触发备份
kubectl annotate -n postgres-operator postgrescluster ai-postgres \
  postgres-operator.crunchydata.com/pgbackrest-backup="$(date '+%Y%m%d-%H%M%S')"

# 缩减/扩展副本数
kubectl patch postgrescluster ai-postgres -n postgres-operator \
  --type='json' -p='[{"op": "replace", "path": "/spec/instances/0/replicas", "value": 2}]'
```

## 故障排查快速参考

| 症状 | 可能原因 | 检查命令 | 解决方案 |
|------|---------|---------|---------|
| Pod 无法启动 | PVC 损坏 | `kubectl describe pod <pod>` | 删除 Pod 和 PVC |
| 无 Leader | 选举失败 | `patronictl list` | 重启 Operator |
| 复制延迟大 | 网络/资源问题 | `patronictl list` | 检查资源和网络 |
| 备份失败 | 存储空间不足 | `./health-check.sh` | 清理旧备份或扩容 |
| 数据损坏 | 文件系统错误 | 查看 Pod 日志 | 从备份恢复 |

## 维护计划

### 每日
- ✅ 运行健康检查脚本
- ✅ 检查备份是否成功

### 每周
- ✅ 验证全量备份存在
- ✅ 检查 PVC 使用率

### 每月
- ✅ 测试恢复流程（非生产环境）
- ✅ 审查告警和日志
- ✅ 更新文档

---

**创建时间**: 2026-03-03  
**维护者**: Infrastructure Team  
**版本**: 1.0

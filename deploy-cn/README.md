# Multica 一键部署包（国内网络适配版）v1

任务包 5 交付物。在官方 selfhost 机制之上补齐四件交付必需品：环境预检、国内镜像源、密钥与隐私默认值、备份/升级闭环。目标：在一台干净的 Linux 主机上，**从零到可登录 ≤ 30 分钟**。

## 一条命令

```bash
git clone <你的 fork 地址> multica && cd multica   # 或任意已含本包的 checkout
bash deploy-cn/install.sh
```

可选参数：`--project 名称`（默认 multica，多套共存时改名）、`--frontend-port`（默认 3000）、`--backend-port`（默认 8080）。

脚本依次做：预检（Docker/Compose/磁盘/内存/端口，其中 /tmp ≥5GB 只警告不拦截）→ 配置 Docker 镜像源（有免密 sudo 才自动写 /etc/docker/daemon.json，原文件先备份；无权限则提示手动配）→ 生成 .env（随机 JWT_SECRET、数据库密码、VCS 密钥；**DO_NOT_TRACK=1 默认关遥测**；文件权限 600）→ 源码构建并启动 → 轮询后端 /health 与前端 200 → 打印访问地址与总用时。重复运行不会重装：检测到已运行会报告状态并提示走升级。

源码构建慢的三个国内卡点已由 dev 分支的基础 commit 处理：Dockerfile 里 GOPROXY=goproxy.cn（后端模块）、npm npmmirror 源（前端依赖）；镜像拉取靠 daemon 镜像源。

## 验收清单（交付时逐项打勾）

- [ ] `bash deploy-cn/install.sh` 一次跑通，总用时记录在案（目标 ≤30 分钟；首次构建时长取决于机器与网络，镜像层有缓存后重跑为分钟级）
- [ ] 前端地址可打开注册/登录页；后端 /health 返回 `{"status":"ok","checks":{"db":"ok","migrations":"ok"}}`
- [ ] .env 权限为 600，密钥非默认值；DO_NOT_TRACK=1
- [ ] `bash deploy-cn/backup.sh` 跑通，backups/ 下有 .sql.gz 且 `gzip -t` 校验通过
- [ ] 客户侧确认：管理员账号已注册、能登录；发信方式已沟通（自托管默认无邮件服务，注册验证码只进数据库——生产交付前必须配 SMTP 或在培训中明确说明）

## 日常运维

| 动作 | 命令 |
|---|---|
| 看状态 | `docker compose -f docker-compose.selfhost.yml -f docker-compose.selfhost.build.yml ps` |
| 看日志 | 同上把 ps 换成 `logs -f backend`（或 frontend） |
| 备份 | `bash deploy-cn/backup.sh`（自动保留最近 14 份；建议 cron 每日跑） |
| 升级 | `bash deploy-cn/upgrade.sh`（强制先备份；拉源码→重建→健康检查，失败给出回滚命令） |
| 停止 | `docker compose -f docker-compose.selfhost.yml down`（数据卷保留） |
| 卸载 | `docker compose -f docker-compose.selfhost.yml down -v`（**连数据卷一起删，不可恢复，先备份**） |

## 已知卡点对照（阶段 2 在真实机器上逐个踩过）

| 现象 | 真因 | 本包处理 |
|---|---|---|
| 构建报 no space left，但主盘还有上百 GB | 临时目录 /tmp 太小（曾遇 512MB tmpfs） | 预检报 /tmp 空间并给警告；部署前检查清单含 `df -h /tmp` |
| Docker Hub 拉 postgres 镜像超时 | 国内直连 registry-1.docker.io 不通 | daemon.json 镜像源（daocloud/1ms.run） |
| 后端构建卡在 go mod download | 容器内直连 proxy.golang.org | dev 分支 Dockerfile 已设 GOPROXY=goproxy.cn |
| 前端依赖安装慢/失败 | npm 官方源慢 | dev 分支 Dockerfile.web 已切 npmmirror |
| git clone 官方仓库超时 | GitHub HTTPS 在部分网络不可达 | 用 fork 的 SSH 地址 clone（git@github.com:…），SSH 通道实测可达 |
| 注册收不到验证码邮件 | 自托管默认未配发信 | 验收清单单列；临时方案：查数据库 verification_code 表 |

## 边界与说明

- 本包是部署编排，不改 Multica 业务代码；与官方版本升级路径兼容（升级即 git pull + 重建）。
- 许可证：自托管自用属 Multica License 免费范围；收费替客户部署在其服务器上属灰区，澄清函未获回复前不对外承诺（见阶段 0 许可证备忘）。
- 干净机「无 Docker」分支走官方安装脚本（阿里云镜像），需要在目标机实测一次后在本文件勾掉此说明——当前版本已在装有 Docker 的机器上完成全流程实测（见验收记录）。

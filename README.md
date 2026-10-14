# PigeonBox Synology DSM

[![CI](https://github.com/pigeonbox/synology/actions/workflows/ci.yml/badge.svg)](https://github.com/pigeonbox/synology/actions/workflows/ci.yml)
[![Release](https://github.com/pigeonbox/synology/actions/workflows/release.yml/badge.svg)](https://github.com/pigeonbox/synology/releases)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)

PigeonBox（文件快递柜，匿名口令分享文本/文件）的 **群晖 Synology DSM 套件包**：基于官方 Docker 镜像（`ghcr.io/pigeonbox/server` + `frontend`）的 docker-compose 编排，装完即用。

- **noarch 单包**：不区分机型架构（x86/ARM 皆可，容器镜像按 NAS 架构自动拉取）
- 安装向导设**端口 / 数据目录 / 管理员密码**，装完浏览器即用
- 套件启停 = 编排启停（App Center/套件中心按钮），开机随套件自动拉起
- JWT 密钥首启自动生成并持久化到数据目录，重启/升级不丢
- **卸载保留数据**（SQLite + 上传文件 + 密钥都在你指定的数据目录）
- 升级套件自动对齐镜像版本（`.env` 的 `PB_IMAGE_TAG` 随包刷新）
- 设备直传：server 镜像自 1.21.0 起随包 p2pc，SPK compose 部署即具设备直传能力；admin「系统配置→P2P」分区热启停联邦与设备直传

> 系统要求：**DSM 7.2+**，且套件中心已安装 **Container Manager**（24.0.2+，编排依赖 `docker compose` v2 子命令）。DSM 7.0/7.1（Docker 套件时代）暂不支持。

## 安装

1. 套件中心 → 右上角 **手动安装** → 上传 `pigeonbox_<版本>.spk`（本仓 [Releases](https://github.com/pigeonbox/synology/releases) 下载）
2. 未签名第三方包会提示「发布者无法验证」，**确认继续**即可（DSM 7.x 无信任级别设置，属预期行为）
3. 按向导设置：
   - **端口**：默认 `12345`（1024-65535）
   - **数据目录**：默认 `/volume1/docker/pigeonbox`（建议放 docker 共享文件夹下；大量文件请指到数据盘所在卷）
   - **管理员密码**：**必填**（安全生产模式，留空=容器拒绝启动；首次启动以此建号，遗失可卸载重装、数据目录保留）
4. 安装完成后套件自动启动，浏览器访问 `http://NAS的IP:12345`（或套件中心该套件详情页点「打开」）

> NAS 首次启动需从 ghcr.io 拉取镜像（约 200MB）。国内网络拉取慢/失败时，可 SSH 到 NAS 手动导入后重启套件：
> ```sh
> sudo docker pull ghcr.io/pigeonbox/server:1.22.0
> sudo docker pull ghcr.io/pigeonbox/frontend:1.22.0
> ```
> （镜像版本以 `数据目录/.env` 里的 `PB_IMAGE_TAG` 为准。）

## 配置

所有配置集中在 `数据目录/.env`（安装时生成，File Station 可编辑；改完在套件中心**停用→启用**套件生效）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_IMAGE_TAG` | `1.22.0` | 镜像版本（升级套件会自动刷新，勿手改） |
| `PB_API_PORT` | `12345` | 对外端口（改动后建议同步改数据目录所在防火墙规则） |
| `PB_DATA_DIR` | 安装向导值 | 数据目录（SQLite+上传文件+JWT 密钥；**备份它=备份全部**） |
| `PB_ADMIN_PASSWORD` | 空 | 管理员密码（**必填**：留空=容器拒绝启动；首次启动以此建号，之后改密码请在网页修改） |
| `PB_SERVER_BASE_URL` | 空 | 对外完整地址（有域名/HTTPS 反代时填，分享链接会用它） |
| `PB_USER_ALLOW_REGISTRATION` | `false` | 开放注册（NAS 场景默认关闭，管理员建号） |
| `PB_JWT_SECRET` | 空 | 留空=数据目录自动生成持久化 |

更多高级项（Redis、存储后端切换、可信代理等）见生态主仓 [ENVIRONMENT_VARIABLES.md](https://github.com/pigeonbox/pigeonbox/blob/main/docs/ENVIRONMENT_VARIABLES.md)；默认即全功能单机模式（免 Redis）。

## 数据与备份

- 全部状态在 `PB_DATA_DIR` 一个目录里：`fileCodeBox.db`（SQLite）、上传文件、`.jwt_secret`
- 备份 = 用 Hyper Backup / File Station 复制该目录（停套件后拷贝最干净）
- 卸载套件**默认保留**数据目录；确认不要了在 File Station 手动删除

## 常见问题

- **取件/上传报权限错误**：数据目录属主需与容器内运行身份一致（uid 1000），SSH 执行
  `sudo chown -R 1000:1000 /volume1/docker/pigeonbox` 后重启套件
- **套件启动失败**：套件中心 → 该套件 → 查看日志；或 SSH `sudo synopkg log pigeonbox`；
  多为 Container Manager 未启动或镜像未拉全
- **改端口后套件中心「打开」按钮仍是旧端口**：INFO 里的 `adminport` 是安装期静态值，
  以 `.env` 的 `PB_API_PORT` 为准

## 开发与构建

共享资产（`compose.yml` / `env.example`）的**真相源在生态主仓 [`deploy/nas/`](https://github.com/pigeonbox/pigeonbox/tree/main/deploy/nas)**：改编排/默认值请改 hub 模板后执行 `bash deploy/nas/sync.sh sync --all`（单仓 `sync --platform <p> --dir <仓>`），**勿直接改本仓这两个文件**——CI 有「与 hub 模板对齐」漂移门禁，模板一动未同步的仓全部变红。跟随 server 新镜像版本走发布列车 v2：hub `make train-bump TRAIN=x.y.z`（`release/trainctl` 状态机）统一完成镜像钉版刷新与各仓打 tag。
仓库结构：`spk/`（INFO 模板 / scripts / conf / WIZARD_UIFILES / 图标 / compose 编排）+ `scripts/build-spk.sh`（纯 tar 组装，无需官方 toolchain）。

```sh
./scripts/build-spk.sh 0.1.0 0001   # → dist/pigeonbox_0.1.0-0001.spk
shellcheck -s sh spk/scripts/*
```

打 `v*` tag 自动：组装 SPK → 挂本仓 Release → 回挂生态主仓 `synology-v*` Release（需 `SYNOLOGY_PAT`，未配置时 CI 放行失败、本地 `gh release upload` 兜底）。

**真机验证状态**：结构断言 + shellcheck 过 CI；DSM 真机安装验证待补（欢迎反馈 issue）。

## 参考（格式来源）

- [SPK 结构与脚本](https://help.synology.com/developer-guide/synology_package/introduction.html)（Synology 官方开发者指南）
- [kryton packaging/synology](https://github.com/azrtydxb/kryton/tree/main/packaging/synology)（ghcr 镜像 + compose + 向导输端口的同构实战）
- [PeerBanHelper SPK](https://github.com/PBH-BTN/PeerBanHelper/tree/master/pkg/synopkg/PeerBanHelperPackage)（noarch + ContainerManager 依赖的活跃先例）
- [SynoCommunity/spksrc](https://github.com/SynoCommunity/spksrc)（权威打包框架）

## License

Apache-2.0（与生态一致，见 [LICENSE](./LICENSE)）。

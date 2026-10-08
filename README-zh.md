<p align="center"><a href="README.md">English</a> | <a href="README-zh.md">中文</a></p>

# kubernetes-100year-binary

构建**默认证书有效期 100 年**的 `kubeadm` 二进制（上游默认：叶子证书 1 年、CA 10 年），每个 Kubernetes 正式版本对应一个分支和一个 Release。

- 上游项目：[kubernetes/kubernetes](https://github.com/kubernetes/kubernetes)
- 发布页：[Releases](https://github.com/xuxiaowei-com-cn/kubernetes-100year-binary/releases)
- 覆盖范围：`v1.24.0` … `v1.37.1`，即该区间内的所有 Kubernetes 正式版本

## 背景

`kubeadm init` 生成的证书默认 1 年过期（CA 10 年），集群需要定期执行 `kubeadm certs renew`。本项目在编译期直接修改有效期常量，因此用这些二进制初始化的集群，证书默认就是 100 年。

本仓库只构建并发布 `kubeadm`。

## 下载安装

在 Releases 页面下载（以 `release-v1.37.1`、amd64 为例，架构按需替换）：

```shell
curl -LO https://github.com/xuxiaowei-com-cn/kubernetes-100year-binary/releases/download/release-v1.37.1/kubeadm-amd64
chmod +x kubeadm-amd64
sudo install -m 0755 kubeadm-amd64 /usr/bin/kubeadm
kubeadm version
```

Release 资产命名为 `kubeadm-<arch>`：

| 架构            | 资产              | 可用版本                 |
|-----------------|-------------------|--------------------------|
| `linux/amd64`   | `kubeadm-amd64`   | 全部版本                 |
| `linux/arm64`   | `kubeadm-arm64`   | 全部版本                 |
| `linux/ppc64le` | `kubeadm-ppc64le` | 全部版本                 |
| `linux/s390x`   | `kubeadm-s390x`   | 全部版本                 |
| `linux/arm`     | `kubeadm-arm`     | 仅 `v1.24.x` – `v1.26.x` |

## 批量下载

[`scripts/download-releases.sh`](scripts/download-releases.sh) 会把所有 Release 产物下载到
`<输出目录>/<版本>/<架构>/kubeadm`；已存在的文件按 Release 资产自带的 SHA-256 校验，不一致则重新下载；
每个版本目录还会生成 `SHA256SUMS`。

```shell
# 全部下载到 ./releases，结构如 ./releases/v1.37.1/amd64/kubeadm
./scripts/download-releases.sh -d ./releases

# 国内网络：给下载地址加代理前缀
./scripts/download-releases.sh -d ./releases --proxy https://gh-proxy.org/ --log download.log

# 只校验不下载（GitHub API 不可用时自动回退到本地 SHA256SUMS）
./scripts/download-releases.sh -d ./releases --verify-only

# 其他常用开关
./scripts/download-releases.sh --list --version-regex '^v1\.3[0-7]\.'   # 只列出，不下载
./scripts/download-releases.sh --arch arm64 -j 8                        # 只下 arm64，8 个并发
./scripts/download-releases.sh --force                                  # 忽略已有文件全部重下
```

离线校验某个版本：

```shell
cd releases/v1.37.1 && sha256sum -c SHA256SUMS
```

## CI 工作原理

[`.github/workflows/build.yml`](.github/workflows/build.yml) 在以下情况触发：推送 `v*` 分支、推送
`release-v*` 标签、Pull Request、手工 dispatch。

1. 从 ref 解析 `K8S_VERSION`（`v1.24.0` 或 `release-v1.24.0` → `v1.24.0`）
2. `git clone --branch "$K8S_VERSION" --depth 1` 拉取上游源码
3. 打 100 年证书补丁
4. `apt-get update && apt-get install -y rsync`
5. 设置 `KUBE_BUILD_PLATFORMS` 后执行 `make all WHAT=cmd/kubeadm`
6. 产物位于 `kubernetes/_output/local/bin/linux/<arch>/kubeadm`
7. 分支推送 → 上传 artifact；标签推送 → 创建 GitHub Release 并附上 `kubeadm-<arch>` 文件
   （本仓库不为预发布版本打标签）

### 100 年证书补丁

| 版本                  | 补丁内容                                                                                                                                                                                                                                                     |
|-----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `v1.24.0` – `v1.30.x` | `staging/src/k8s.io/client-go/util/cert/cert.go`：`duration365d * 10` → `duration365d * 100`<br>`cmd/kubeadm/app/constants/constants.go`：`CertificateValidity = time.Hour * 24 * 365` → `time.Hour * 24 * 365 * 100`                                        |
| `v1.31.0` 及以后      | 同样打 `cert.go`；`constants.go` 改为两个常量：`CACertificateValidityPeriod`（`* 24 * 365 * 10` → 100 年）与 `CertificateValidityPeriod`（`* 24 * 365` → 100 年）；并注释掉 `cmd/kubeadm/app/util/pkiutil/pki_helpers.go` 里的两处 `notAfter = cfg.NotAfter` |

`v1.31.0` 把 `CertificateValidity` 重命名为 `CertificateValidityPeriod`、新增了独立的 CA 常量，并把 CA 创建
移到了 kubeadm 自身；同时允许 `ClusterConfiguration.certificateValidityPeriod` /
`caCertificateValidityPeriod` 通过 `cfg.NotAfter` 覆盖编译期默认值 —— 所以 1.31+ 的分支会禁用该覆盖，
保证 100 年始终生效。

### 构建容器

`container` 取该 Kubernetes 版本要求的 Go 版本：`build/dependencies.yaml` 里的
`golang: upstream version`，`v1.35.0` 及以后取 `.go-version`。

注意镜像基底：部分 bullseye 镜像（`golang:1.18.x`、`golang:1.20.3`、`golang:1.20.4`）里
`apt-get install -y rsync` 会失败，因此 `v1.24.x` 使用 `golang:1.19.13`，`v1.27.0`–`v1.27.2` 使用
`golang:1.20.5`（bookworm），而不是上游标注的精确版本。

### 平台

`KUBE_BUILD_PLATFORMS` 与上游 `hack/lib/golang.sh` 的 `KUBE_SUPPORTED_SERVER_PLATFORMS` 保持一致。
上游在 `v1.27.0` 移除了 `linux/arm`，因此这些分支只构建和发布 4 个平台。

## 版本矩阵

| Kubernetes | 分支数                       | 平台                         | 构建容器                                                  |
|------------|------------------------------|------------------------------|-----------------------------------------------------------|
| `v1.24.x`  | 18（`v1.24.0` – `v1.24.17`） | 4 平台 + `linux/arm`         | `golang:1.19.13`；从 `v1.24.16` 起为 `1.20.6`/`1.20.7`    |
| `v1.25.x`  | 17（`v1.25.0` – `v1.25.16`） | 4 平台 + `linux/arm`         | `golang:1.19.13`；从 `v1.25.12` 起为 `1.20.6` – `1.20.10` |
| `v1.26.x`  | 16（`v1.26.0` – `v1.26.15`） | 4 平台 + `linux/arm`         | `golang:1.19.13`；从 `v1.26.7` 起为 `1.20.6` – `1.21.8`   |
| `v1.27.x`  | 17（`v1.27.0` – `v1.27.16`） | amd64、arm64、ppc64le、s390x | `1.20.5` – `1.22.5`                                       |
| `v1.28.x`  | 16（`v1.28.0` – `v1.28.15`） | amd64、arm64、ppc64le、s390x | `1.20.7` – `1.22.8`                                       |
| `v1.29.x`  | 16（`v1.29.0` – `v1.29.15`） | amd64、arm64、ppc64le、s390x | `1.21.5` – `1.23.6`                                       |
| `v1.30.x`  | 15（`v1.30.0` – `v1.30.14`） | amd64、arm64、ppc64le、s390x | `1.22.2` – `1.23.10`                                      |
| `v1.31.x`  | 15（`v1.31.0` – `v1.31.14`） | amd64、arm64、ppc64le、s390x | `1.22.5` – `1.24.9`                                       |
| `v1.32.x`  | 14（`v1.32.0` – `v1.32.13`） | amd64、arm64、ppc64le、s390x | `1.23.3` – `1.24.13`                                      |
| `v1.33.x`  | 14（`v1.33.0` – `v1.33.13`） | amd64、arm64、ppc64le、s390x | `1.24.2` – `1.25.11`                                      |
| `v1.34.x`  | 13（`v1.34.0` – `v1.34.12`） | amd64、arm64、ppc64le、s390x | `1.24.6` – `1.26.5`                                       |
| `v1.35.x`  | 10（`v1.35.0` – `v1.35.9`）  | amd64、arm64、ppc64le、s390x | `1.25.5` – `1.26.8`                                       |
| `v1.36.x`  | 6（`v1.36.0` – `v1.36.5`）   | amd64、arm64、ppc64le、s390x | `1.26.2` – `1.26.8`                                       |
| `v1.37.x`  | 2（`v1.37.0`、`v1.37.1`）    | amd64、arm64、ppc64le、s390x | `1.26.6` – `1.26.8`                                       |

每个版本都有一个 `vX.Y.Z` 分支（与上游 tag 同名）和一个轻量标签 `release-vX.Y.Z`，由标签触发 GitHub Release。

## 维护

新增一个 Kubernetes 版本：

1. 到上游确认：`build/dependencies.yaml` / `.go-version` 要求的 Go 版本、`hack/lib/golang.sh` 的平台列表、
   以及上面两个补丁锚点是否仍然存在
2. 以 `v1.24.0` 分支为基线新建分支，修改容器、平台列表和补丁步骤
3. 提交（`:gitmoji:` 前缀 + `Signed-off-by` DCO），并打标签 `release-vX.Y.Z`
4. 推送：分支可以一次批量推，**标签不行**

### 推送标签

GitHub 在**单次 push 创建超过 3 个标签**时不会创建 workflow run，所以 `git push origin --tags` 会静默地
不触发任何构建（[社区讨论](https://github.com/orgs/community/discussions/56152)）。请每次最多推送 3 个标签；
已经推上去但没触发的标签，可以直接 dispatch：

```shell
git push origin release-v1.37.0 release-v1.37.1     # 每次最多 3 个标签
gh workflow run build.yml --ref release-v1.37.0     # 不重推标签，直接触发某个标签
```

## 仓库结构

```
.github/workflows/build.yml    CI 定义
scripts/download-releases.sh   批量下载 Release 产物（SHA-256 校验、支持代理）
skills/                        本仓库使用的提交规范（DCO、Gitmoji）
```

---
title: 子模块拉取（国内网络）
---

# 子模块拉取（国内网络）

> 适用场景：`git clone --recurse-submodules` 卡住；GitHub / git.kernel.org 连接超时、被 RST；`third_party/` 下的子模块目录为空，或只剩一个 `.git`。
>
> 一键脚本：`document/development/setup-submodules.sh`（可重复执行，已就绪的组件会跳过）

IMX-Forge 用 6 个 git submodule 管理第三方源码。它们的体积和托管站点如下：

| 子模块 | 托管站点 | 浅克隆 ref | 大约体积 |
|---|---|---|---|
| `third_party/buildmeter` | GitHub | `main` | 27 KB |
| `third_party/buildroot` | GitHub | tag `2026.02` | 61 MB |
| `third_party/busybox` | GitHub | `master` | 20 MB |
| `third_party/linux_mainline` | git.kernel.org | tag `v7.2.9` | 2.1 GB |
| `third_party/qemu` | GitHub | tag `v11.1.0` | 211 MB |
| `third_party/uboot-mainline` | GitHub | tag `v2026.10` | 418 MB |

## 为什么会失败

1. **网络**：国内直连 `github.com:443`、`git.kernel.org:443` 经常超时或被 RST，典型报错是
   `curl 56 Recv failure`、`fatal: invalid ls-refs response`、`Failed to connect to github.com port 443`。
2. **递归**：`--recurse-submodules` / `git submodule update --init --recursive` 会继续进入 QEMU
   自带的 15 个 `roms/*` 嵌套子模块（托管在 gitlab.com），在国内网络下几乎必卡；而本项目的
   QEMU 只构建 `arm-softmmu`，根本不需要这些 roms。
3. **半成品 checkout**：克隆过程被打断后，buildroot / busybox / buildmeter 可能出现“日志显示
   克隆成功、但 index 为空、工作区也是空的”。更麻烦的是 `.gitmodules` 里配了
   `ignore = dirty`，超级项目的 `git status` 完全看不出子模块已经损坏。

## 快速使用

```bash
cd /path/to/imx-forge

# 拉取缺失的子模块 + 自动修复“空 index / 空工作区”的半成品
bash document/development/setup-submodules.sh

# 只检查，不做任何修改；全部就绪时退出码为 0
bash document/development/setup-submodules.sh --check

# HEAD 与锁定 commit 不一致/目录损坏时，强制回到锁定 commit
# 注意：会丢弃子模块里的未提交改动，执行前先确认
bash document/development/setup-submodules.sh --force

# 只处理某几个子模块（名字或路径均可，可重复）
bash document/development/setup-submodules.sh --only qemu --only linux_mainline

# 顺便把 wireless-regdb 预克隆到 out/firmwares，避免首次内核构建再去连 kernel.org
bash document/development/setup-submodules.sh --with-regdb
```

## 脚本做了什么

1. 用 `git ls-tree HEAD third_party/<name>` **动态读取**超级项目锁定的 commit，不硬编码 SHA。
2. 未初始化的子模块：按“国内镜像 → 官方源”的顺序逐个尝试
   `git clone --depth 1 --branch <ref> --single-branch`，成功后再 `git reset --hard <锁定 commit>`。
3. 已初始化但属于“克隆中断残留”（index 为空、工作区也为空）：自动 `git reset --hard` 恢复文件。
4. 已初始化但 HEAD 与锁定 commit 不一致：默认只提示，避免误删开发中的改动；加 `--force` 才重置。
5. 执行 `git submodule init` 把 `.gitmodules` 的 URL 注册进 `.git/config`，再用
   `git submodule absorbgitdirs` 把新克隆的 `.git` 收编到超级项目的 `.git/modules/` 下。
6. 可选：预克隆 wireless-regdb。

镜像顺序（可在脚本顶部的 `COMPONENTS` 表里调整）：

- GitHub 仓库（buildmeter / buildroot / busybox / qemu / uboot）：
  `ghfast.top` → `ghproxy.net` → `github.com`
- Linux 内核（linux_mainline）：
  `TUNA` → `BFSU` → `NJU` → `git.kernel.org`

脚本还加了 `http.lowSpeedLimit=1000` / `http.lowSpeedTime=45`，链路卡死时会在 45 秒左右失败并切到下一个镜像，不会无限等。

## 手动操作（等价命令）

不想用脚本时，可以按下面的步骤手动来。**先只克隆项目本体，不要加 `--recurse-submodules`**：

```bash
git clone https://github.com/Awesome-Embedded-Learning-Studio/imx-forge.git
cd imx-forge
```

然后按需浅克隆 6 个子模块（镜像不可用时换 `ghproxy.net` 或官方源）：

```bash
git clone --depth 1 --branch main \
  https://ghfast.top/https://github.com/Awesome-Embedded-Learning-Studio/buildmeter third_party/buildmeter

git clone --depth 1 --branch 2026.02 \
  https://ghfast.top/https://github.com/buildroot/buildroot.git third_party/buildroot

git clone --depth 1 --branch master \
  https://ghfast.top/https://github.com/mirror/busybox.git third_party/busybox

git clone --depth 1 --branch v7.2.9 --single-branch \
  https://mirrors.tuna.tsinghua.edu.cn/git/linux-stable.git third_party/linux_mainline

git clone --depth 1 --branch v11.1.0 --single-branch \
  https://ghfast.top/https://github.com/qemu/qemu.git third_party/qemu

git clone --depth 1 --branch v2026.10 --single-branch \
  https://ghfast.top/https://github.com/u-boot/u-boot.git third_party/uboot-mainline
```

克隆完成后，逐个对齐到超级项目锁定的 commit（tag/分支之后可能前移，这一步保证精确锁定）：

```bash
pin() { git ls-tree HEAD "third_party/$1" | awk '{print $3}'; }

for n in buildmeter buildroot busybox linux_mainline qemu uboot-mainline; do
  git -C "third_party/$n" reset --hard "$(pin "$n")"
done
```

最后注册子模块并收编 `.git`：

```bash
git submodule init
git submodule absorbgitdirs
```

## 验证

```bash
# 六行都应以空格开头；行首是 '-' 表示未注册/未初始化，'+' 表示 HEAD 与 gitlink 不一致
git submodule status

# 不要加 --recursive；子模块已就位时应当秒过
git submodule update --init

# 逐个检查工作区（超级项目的 git status 看不到子模块脏，因为 ignore = dirty）
git submodule foreach --quiet \
  'test -z "$(git status --porcelain)" || echo "$sm_path 不干净"'
```

## 常见现象排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `curl 56 Recv failure` / `invalid ls-refs response` | kernel.org / GitHub 传输被重置 | 用镜像或脚本重跑 |
| `Failed to connect to github.com port 443` | GitHub 直连不通 | 用 `ghfast.top` / `ghproxy.net` |
| 克隆日志成功，但目录里只有 `.git` | checkout 未完成，index 为空 | 跑脚本；或手动 `git reset --hard $(pin <name>)` |
| 超级项目 `git status` 干净，但子模块缺文件 | `ignore = dirty` 掩盖了子模块状态 | 必须进子模块执行 `git status` |
| `git submodule status` 行首是 `-`，但目录里有文件 | 没有执行 `git submodule init`，URL 未注册 | 跑脚本，或 `git submodule init` |
| `--recursive` 卡在 `roms/QemuMacDrivers` | 进入了 gitlab.com 上的嵌套子模块 | 不要递归；本项目构建不需要 roms |
| 首次内核构建卡在 `wireless-regdb` | `build-linux.sh` 会去 clone git.kernel.org | 加 `--with-regdb` 预置，或按脚本里的镜像手动 clone |
| 上游更新了锁定 commit，脚本报“拿不到锁定 commit” | `COMPONENTS` 里的 ref 还是旧 tag | 把对应 ref 改成新 tag；分支 tip 也可以 |

::: tip 关于构建脚本
`scripts/build_helper/build-qemu.sh` 会先确认 `third_party/qemu` 的 HEAD 等于超级项目里的
gitlink，再依次 `git apply patches/qemu/*.patch`；`scripts/lib/release.sh` 也会用
`git describe --tags` 取版本。所以子模块必须停在锁定 commit，且浅克隆要带上 tag ——
上面的做法已经满足这两点。
:::

## 已验证的版本（2026-11-09）

| 子模块 | 锁定 commit（短） | 实际 tag/分支 | 文件数 |
|---|---|---|---|
| buildmeter | `dff2a1d` | main | 12 |
| buildroot | `52ee2f5` | 2026.02 | 15020 |
| busybox | `371fe9f` | master | 2889 |
| linux_mainline | `5fce161` | v7.2.9 | 94874 |
| qemu | `84f0721` | v11.1.0 | 11249 |
| uboot-mainline | `5508406` | v2026.10 | 38480 |

在该状态下，6 个子模块的 `git status` 均为空，`git submodule update --init` 为 0.01s 的 no-op，
`patches/qemu` 下的 16 个补丁也能在 `third_party/qemu` 上按顺序干净应用。

## 相关文件

- `.gitmodules`：子模块 URL、`shallow = true`、`ignore = dirty`
- `scripts/build_helper/build-qemu.sh`：校验 gitlink 后应用 QEMU 补丁
- `scripts/build_helper/build-linux.sh`：首次构建时把 wireless-regdb 克隆到 `out/firmwares/`
- `scripts/lib/release.sh`：发布流程会 `git describe --tags` 并 reset 到 gitlink

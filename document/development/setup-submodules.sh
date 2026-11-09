#!/usr/bin/env bash
#
# setup-submodules.sh - 在国内网络环境下正确拉取 / 修复 imx-forge 的 third_party 子模块
#
# 背景:
#   GitHub、git.kernel.org 在国内经常连不上或被 RST; 直接
#   `git clone --recurse-submodules` 还会递归进 QEMU 自带的 roms/*
#   子模块(gitlab.com), 必卡。本脚本只处理顶层 6 个子模块, 走国内镜像,
#   并强制对齐到超级项目锁定的 commit。
#
# 用法:
#   bash document/development/setup-submodules.sh
#       初始化缺失的子模块; 自动修复 "克隆中断导致 index/工作区为空" 的子模块。
#       已存在且 HEAD 与锁定 commit 不一致时只提示, 不覆盖。
#
#   bash document/development/setup-submodules.sh --check
#       只检查, 不做任何修改。全部就绪时退出码为 0。
#
#   bash document/development/setup-submodules.sh --force
#       对 HEAD 不一致或损坏的子模块执行 reset --hard 到锁定 commit。
#       !!! 会丢弃子模块里的未提交改动, 请先确认 !!!
#
#   bash document/development/setup-submodules.sh --only qemu --only linux_mainline
#       只处理指定子模块(名字或路径均可, 可重复)。
#
#   bash document/development/setup-submodules.sh --with-regdb
#       顺带把 wireless-regdb 预克隆到 out/firmwares/wireless-regdb,
#       避免首次内核构建时再去连 git.kernel.org。
#
# 说明:
#   - 锁定 commit 从 `git ls-tree HEAD third_party/<name>` 动态读取,
#     所以不需要在本脚本里手工同步 SHA。
#   - 下面 COMPONENTS 表里的 ref 只是 "用哪个 tag/分支去浅克隆" 的起点;
#     如果上游锁定的 commit 更新了, 需要把对应的 ref 改成新 tag
#     (分支 tip 也可以, 脚本会再 reset 到锁定 commit)。
#   - 绝不使用 --recursive, 也不会去初始化 QEMU 的 roms/* 子模块。
#
set -uo pipefail

# ---------------------------------------------------------------- 输出辅助
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_RESET=''
fi
info() { printf '[info] %s\n' "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[err ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

CHECK_ONLY=0
FORCE=0
WITH_REGDB=0
ONLY=()
SELECTED=0
FAIL=0
CLONED=()
SELECTED_PATHS=()
# 是否已经执行过 --only: 用来在结尾提示 "没有匹配的组件"
HAVE_ONLY=0

usage() {
  sed -n '3,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check)       CHECK_ONLY=1 ;;
    --force)       FORCE=1 ;;
    --with-regdb)  WITH_REGDB=1 ;;
    --only)
      shift
      if [ $# -eq 0 ]; then err "--only 需要一个子模块名或路径"; exit 2; fi
      ONLY+=("$1"); HAVE_ONLY=1 ;;
    --only=*)      ONLY+=("${1#*=}"); HAVE_ONLY=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             err "未知参数: $1"; usage; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- 仓库根目录
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$ROOT" ]; then
  ROOT=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)
fi
if [ -z "$ROOT" ]; then
  err "找不到 git 仓库根目录; 请在 imx-forge 仓库内运行本脚本。"
  exit 1
fi
cd "$ROOT" || exit 1
if [ ! -f "$ROOT/.gitmodules" ]; then
  err "$ROOT 不是 imx-forge 仓库根目录(缺少 .gitmodules)。"
  exit 1
fi

# ---------------------------------------------------------------- 子模块表
# 格式: 名字|仓库内路径|浅克隆用的 ref|镜像 URL(空格分隔, 按顺序尝试)
#
# ref 说明:
#   - linux_mainline / qemu / uboot-mainline / buildroot 用 tag(不可变, 最稳);
#   - busybox / buildmeter 的锁定 commit 是 master/main 的 tip, 用分支;
#     若上游分支已前移导致浅克隆里没有锁定 commit, 脚本会尝试
#     `git fetch --depth 1 origin <sha>` 和 `git fetch --unshallow`。
COMPONENTS=$(cat <<'EOF'
buildmeter|third_party/buildmeter|main|https://ghfast.top/https://github.com/Awesome-Embedded-Learning-Studio/buildmeter.git https://ghproxy.net/https://github.com/Awesome-Embedded-Learning-Studio/buildmeter.git https://github.com/Awesome-Embedded-Learning-Studio/buildmeter.git
buildroot|third_party/buildroot|2026.02|https://ghfast.top/https://github.com/buildroot/buildroot.git https://ghproxy.net/https://github.com/buildroot/buildroot.git https://github.com/buildroot/buildroot.git
busybox|third_party/busybox|master|https://ghfast.top/https://github.com/mirror/busybox.git https://ghproxy.net/https://github.com/mirror/busybox.git https://github.com/mirror/busybox.git
linux_mainline|third_party/linux_mainline|v7.2.9|https://mirrors.tuna.tsinghua.edu.cn/git/linux-stable.git https://mirrors.bfsu.edu.cn/git/linux-stable.git https://mirror.nju.edu.cn/git/linux-stable.git https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
qemu|third_party/qemu|v11.1.0|https://ghfast.top/https://github.com/qemu/qemu.git https://ghproxy.net/https://github.com/qemu/qemu.git https://github.com/qemu/qemu.git
uboot-mainline|third_party/uboot-mainline|v2026.10|https://ghfast.top/https://github.com/u-boot/u-boot.git https://ghproxy.net/https://github.com/u-boot/u-boot.git https://github.com/u-boot/u-boot.git
EOF
)

is_selected_path() {
  local p=$1 x
  for x in "${SELECTED_PATHS[@]}"; do
    if [ "$x" = "$p" ]; then
      return 0
    fi
  done
  return 1
}

selected() {
  local name=$1 path=$2 o
  if [ ${#ONLY[@]} -eq 0 ]; then
    return 0
  fi
  for o in "${ONLY[@]}"; do
    if [ "$o" = "$name" ] || [ "$o" = "$path" ]; then
      return 0
    fi
  done
  return 1
}

# 目录里除了 .git 之外是否还有内容
dir_has_files() {
  local d=$1
  [ -n "$(find "$d" -mindepth 1 -maxdepth 1 ! -name '.git' -print -quit 2>/dev/null)" ]
}

# 校验并补齐浅克隆里缺失的锁定 commit
ensure_pin() {
  local d=$1 pin=$2
  if git -C "$d" cat-file -e "${pin}^{commit}" 2>/dev/null; then
    return 0
  fi
  info "  锁定 commit ${pin:0:12} 不在浅克隆中, 尝试按 SHA 抓取 ..."
  if GIT_TERMINAL_PROMPT=0 git -C "$d" fetch --depth 1 origin "$pin" 2>/dev/null; then
    return 0
  fi
  info "  按 SHA 抓取失败, 尝试解除浅克隆(可能较慢) ..."
  if GIT_TERMINAL_PROMPT=0 git -C "$d" fetch --unshallow origin 2>/dev/null; then
    return 0
  fi
  return 1
}

# 用镜像顺序尝试克隆到 $dest
clone_component() {
  local name=$1 dest=$2 ref=$3 urlstr=$4
  local tmp="$dest.tmp.$$" url
  local -a urls
  read -r -a urls <<< "$urlstr"

  rm -rf "$tmp"
  mkdir -p "$(dirname -- "$dest")"
  for url in "${urls[@]}"; do
    info "  克隆 $name <- $url"
    if GIT_TERMINAL_PROMPT=0 \
         git -c advice.detachedHead=false \
             -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=45 \
         clone --depth 1 --branch "$ref" --single-branch "$url" "$tmp"; then
      rm -rf "$dest"
      mv "$tmp" "$dest"
      return 0
    fi
    warn "  该镜像失败, 尝试下一个 ..."
    rm -rf "$tmp"
  done
  rm -rf "$tmp"
  return 1
}

# ---------------------------------------------------------------- 主循环
while IFS='|' read -r name path ref urlstr; do
  [ -n "$name" ] || continue
  if ! selected "$name" "$path"; then
    continue
  fi
  SELECTED=$((SELECTED + 1))
  SELECTED_PATHS+=("$path")

  dest="$ROOT/$path"
  pin=$(git -C "$ROOT" ls-tree HEAD -- "$path" | awk '{print $3}')
  echo
  info "== $name ($path) =="
  if [ -z "$pin" ]; then
    err "  HEAD 中找不到子模块 $path (git ls-tree 无输出)"
    FAIL=$((FAIL + 1))
    continue
  fi
  info "  锁定 commit: $pin"

  # --- 情况 1: 已初始化 ---------------------------------------------------
  if [ -e "$dest/.git" ]; then
    head=$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)
    if [ -z "$head" ]; then
      # .git 在, 但 gitdir 损坏
      if [ "$FORCE" -eq 1 ]; then
        warn "  子模块 .git 损坏, --force 重新克隆"
        rm -rf "$dest"
      else
        warn "  子模块 .git 损坏; 加 --force 可重新克隆: $dest"
        FAIL=$((FAIL + 1))
        continue
      fi
    else
      if [ "$head" = "$pin" ]; then
        # HEAD 正确, 但检查是否是 "克隆中断" 留下的空 index/空工作区
        if [ "$(git -C "$dest" ls-files | wc -l)" -eq 0 ] && ! dir_has_files "$dest"; then
          if [ "$CHECK_ONLY" -eq 1 ]; then
            warn "  index/工作区为空(克隆中断残留); 去掉 --check 运行即可自动修复"
            FAIL=$((FAIL + 1))
            continue
          fi
          warn "  检测到空 index/空工作区(克隆中断残留), 执行 reset --hard 修复"
          if git -C "$dest" reset --hard "$pin" >/dev/null 2>&1; then
            ok "  已恢复: $(git -C "$dest" ls-files | wc -l) 个文件"
          else
            err "  reset --hard 失败"
            FAIL=$((FAIL + 1))
            continue
          fi
        elif [ "$(git -C "$dest" ls-files | wc -l)" -eq 0 ]; then
          if [ "$FORCE" -eq 1 ]; then
            warn "  index 为空但工作区有内容, --force 重置"
            if git -C "$dest" reset --hard "$pin" >/dev/null 2>&1; then
              ok "  已恢复: $(git -C "$dest" ls-files | wc -l) 个文件"
            else
              err "  reset --hard 失败"
              FAIL=$((FAIL + 1))
            fi
          else
            warn "  index 为空但工作区有内容, 不自动处理; 请人工检查: $dest"
            FAIL=$((FAIL + 1))
          fi
          continue
        fi
        ok "  HEAD 与锁定 commit 一致"
        continue
      fi

      # HEAD 不一致
      if [ "$FORCE" -eq 1 ]; then
        warn "  HEAD ${head:0:12} != 锁定 ${pin:0:12}, --force 重置"
        if ensure_pin "$dest" "$pin" && git -C "$dest" reset --hard "$pin" >/dev/null 2>&1; then
          ok "  已重置到 $pin"
          continue
        fi
        err "  重置失败; 可删除 $dest 后重跑本脚本"
        FAIL=$((FAIL + 1))
        continue
      fi
      warn "  HEAD ${head:0:12} != 锁定 ${pin:0:12}"
      warn "  未自动修改(避免丢改动); 需要时加 --force 重置"
      FAIL=$((FAIL + 1))
      continue
    fi
  fi

  # --- 情况 2: 目录存在但不是可用的子模块 --------------------------------
  if [ -e "$dest" ]; then
    if [ ! -d "$dest" ] || [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
      if [ "$FORCE" -eq 1 ]; then
        warn "  目录异常/非空, --force 清理后重新克隆: $dest"
        case "$dest" in
          "$ROOT"/third_party/*) rm -rf "$dest" ;;
          *) err "  路径不在 third_party/ 下, 拒绝删除: $dest"; FAIL=$((FAIL + 1)); continue ;;
        esac
      else
        err "  目录已存在但不是可用子模块, 请人工检查: $dest"
        FAIL=$((FAIL + 1))
        continue
      fi
    fi
  fi

  # --- 情况 3: 未初始化, 开始克隆 ---------------------------------------
  if [ "$CHECK_ONLY" -eq 1 ]; then
    warn "  未初始化(缺少 $path/.git)"
    FAIL=$((FAIL + 1))
    continue
  fi

  if ! clone_component "$name" "$dest" "$ref" "$urlstr"; then
    err "  所有镜像都失败: $name"
    FAIL=$((FAIL + 1))
    continue
  fi
  CLONED+=("$path")

  if ! ensure_pin "$dest" "$pin"; then
    err "  克隆成功但拿不到锁定 commit ${pin:0:12}; 可能上游锁定的 commit 已变,"
    err "  请更新脚本里 $name 的 ref(当前为 $ref), 或手动全量克隆后 reset。"
    FAIL=$((FAIL + 1))
    continue
  fi

  if git -C "$dest" reset --hard "$pin" >/dev/null 2>&1; then
    ok "  就绪: $(git -C "$dest" describe --tags --always 2>/dev/null || echo "$pin"), $(git -C "$dest" ls-files | wc -l) 个文件"
  else
    err "  reset --hard $pin 失败"
    FAIL=$((FAIL + 1))
  fi
done <<< "$COMPONENTS"

# 把 .gitmodules 里的 URL 注册进 .git/config; 否则 `git submodule status`
# 会一直把手工克隆的目录标成未初始化("-")
if [ "$CHECK_ONLY" -eq 0 ] && [ "${#SELECTED_PATHS[@]}" -gt 0 ]; then
  git -C "$ROOT" submodule init -- "${SELECTED_PATHS[@]}" >/dev/null 2>&1 || \
    warn "git submodule init 未成功(可能影响 git submodule status 的显示)"
fi

# 把新克隆子模块的 .git 吸收到超级项目的 .git/modules 下(可选, 但更整洁)
if [ "${#CLONED[@]}" -gt 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
  info "== 收编 .git 目录 (absorbgitdirs) =="
  if ! git -C "$ROOT" submodule absorbgitdirs "${CLONED[@]}" 2>/dev/null; then
    warn "absorbgitdirs 未成功(不影响构建, 可忽略)"
  fi
fi

# ---------------------------------------------------------------- wireless-regdb
prepare_regdb() {
  local dir="$ROOT/out/firmwares/wireless-regdb"
  local -a urls=(
    "https://ghfast.top/https://github.com/sforshee/wireless-regdb.git"
    "https://ghproxy.net/https://github.com/sforshee/wireless-regdb.git"
    "https://github.com/sforshee/wireless-regdb.git"
    "https://git.kernel.org/pub/scm/linux/kernel/git/sforshee/wireless-regdb.git"
  )
  local url

  echo
  info "== wireless-regdb (out/firmwares) =="
  if [ -d "$dir" ]; then
    ok "  已存在, 跳过: $dir"
    return 0
  fi
  if [ "$CHECK_ONLY" -eq 1 ]; then
    warn "  尚未预克隆; 首次内核构建会去连 git.kernel.org"
    return 1
  fi
  mkdir -p "$ROOT/out/firmwares"
  for url in "${urls[@]}"; do
    info "  克隆 <- $url"
    if GIT_TERMINAL_PROMPT=0 \
         git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=45 \
         clone --depth 1 "$url" "$dir"; then
      ok "  完成: $dir"
      return 0
    fi
    warn "  该镜像失败, 尝试下一个 ..."
    rm -rf "$dir"
  done
  warn "  wireless-regdb 预克隆失败; 内核构建时会自动重试(可能再次遇到 git.kernel.org 慢/断)"
  return 1
}

if [ "$WITH_REGDB" -eq 1 ]; then
  prepare_regdb || true
elif [ "$CHECK_ONLY" -eq 1 ]; then
  [ -d "$ROOT/out/firmwares/wireless-regdb" ] || warn "未预置 out/firmwares/wireless-regdb (可加 --with-regdb)"
fi

# ---------------------------------------------------------------- 结果
echo
info "== 当前子模块状态 =="
git -C "$ROOT" submodule status || true

if [ "$HAVE_ONLY" -eq 1 ] && [ "$SELECTED" -eq 0 ]; then
  err "--only 没有匹配到任何子模块: ${ONLY[*]}"
  exit 2
fi

# 最终校验: 被选中的子模块, status 行都应以空格开头(无 +/-/U 标记)
bad_marker=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  line_path=$(printf '%s\n' "$line" | awk '{print $2}')
  if [ "$HAVE_ONLY" -eq 1 ] && ! is_selected_path "$line_path"; then
    continue
  fi
  case "$line" in
    ' '*) ;;
    *) bad_marker=1 ;;
  esac
done < <(git -C "$ROOT" submodule status)

echo
if [ "$FAIL" -ne 0 ] || [ "$bad_marker" -ne 0 ]; then
  err "未全部就绪: $FAIL 个组件有问题, status 标记异常=$bad_marker"
  [ "$FORCE" -eq 0 ] && err "可先看上面的提示; 确认子模块里没有要保留的改动后, 用 --force 重试。"
  exit 1
fi
ok "全部子模块已就绪, 且 HEAD 与超级项目锁定 commit 一致。"
exit 0

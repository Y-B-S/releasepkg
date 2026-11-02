#!/usr/bin/env bash
# Knowcut 一键安装脚本（curl | bash）
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/Y-B-S/releasepkg/main/install.sh | bash
#
#   # 指定版本
#   curl -fsSL .../install.sh | bash -s -- --version 0.2.1
#
#   # 只看会发生什么，不实际改动系统
#   curl -fsSL .../install.sh | bash -s -- --dry-run
#
# 可选参数：
#   --version <v>   安装指定版本（默认 latest）
#   --dest <dir>    安装目录（默认 /Applications，不可写时退回 ~/Applications）
#   --no-launch     安装完不自动打开
#   --dry-run       只打印计划，不下载不安装
#   --uninstall     卸载 Knowcut
#   -h, --help      帮助
#
# 工作原理：
#   用 curl 下载 → curl 不会给文件打 com.apple.quarantine 标记
#   → 因此不触发 Gatekeeper 拦截，未公证也能正常安装运行。
#   （用浏览器下载才会有那个标记，这是本脚本相对「双击 DMG」的核心优势。）
#
# 依赖：macOS + curl + hdiutil + ditto（全部系统自带，无需 Xcode）

set -euo pipefail

# ── 配置：改发版仓库时只需要动这里 ──────────────────────────────
REPO="Y-B-S/releasepkg"
APP_NAME="Knowcut"
APP_BUNDLE="konwcut.app"
EXEC_NAME="local-media-engine"
BUNDLE_ID="com.localmedia.engine"

VERSION="latest"
DEST_DIR="/Applications"
DO_LAUNCH=1
DRY_RUN=0
DO_UNINSTALL=0

# ── 参数解析 ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --dest)      DEST_DIR="$2"; shift 2 ;;
    --no-launch) DO_LAUNCH=0; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（--help 查看用法）" >&2; exit 2 ;;
  esac
done

info() { echo "$@"; }
warn() { echo "⚠️  $*" >&2; }
die()  { echo "❌ $1" >&2; exit "${2:-1}"; }

# ── 前置检查 ────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || die "本脚本只支持 macOS"
MACHINE_ARCH="$(uname -m)"
[[ "${MACHINE_ARCH}" == "arm64" ]] || die "本安装包是 Apple 芯片(arm64)专用，当前机器是 ${MACHINE_ARCH}。
   Intel Mac 需要从源码自行构建：见项目仓库 README 的「快速开始」。" 3

# ── 卸载路径 ────────────────────────────────────────────────────
if [[ ${DO_UNINSTALL} -eq 1 ]]; then
  TARGET=""
  for d in "${DEST_DIR}" "${HOME}/Applications"; do
    [[ -d "${d}/${APP_BUNDLE}" ]] && TARGET="${d}/${APP_BUNDLE}" && break
  done
  [[ -n "${TARGET}" ]] || die "没有找到已安装的 ${APP_BUNDLE}"
  info "==> 卸载 ${TARGET}"
  if [[ ${DRY_RUN} -eq 1 ]]; then
    info "    （dry-run）将删除 ${TARGET}，保留用户数据 ~/.local-media-engine"
    exit 0
  fi
  pgrep -f "${TARGET}/Contents/MacOS/" >/dev/null 2>&1 && {
    info "    退出正在运行的实例..."
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    sleep 2
    pkill -f "${TARGET}/Contents/MacOS/" >/dev/null 2>&1 || true
    sleep 1
  }
  rm -rf "${TARGET}"
  info "    ✅ 已删除应用"
  info ""
  info "用户数据仍保留在 ~/.local-media-engine（含模型约 10GB）。"
  info "如需彻底清除：rm -rf ~/.local-media-engine"
  exit 0
fi

info "==> 目标机器: $(sw_vers -productName) $(sw_vers -productVersion) / ${MACHINE_ARCH}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/knowcut-install.XXXXXX")"
MOUNTED=""
cleanup() {
  [[ -n "${MOUNTED}" ]] && hdiutil detach "${MOUNTED}" -quiet -force >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

# ── 1. 解析版本与下载地址 ──────────────────────────────────────
info "==> 1/6 解析版本"
API="https://api.github.com/repos/${REPO}/releases"
if [[ "${VERSION}" == "latest" ]]; then
  RELEASE_URL="${API}/latest"
else
  RELEASE_URL="${API}/tags/v${VERSION}"
fi

# 用 -w 区分「404 还没发版」和「真的连不上」，否则会把发版缺失报成网络问题，
# 用户会去查代理，实际只是维护者还没传包。
HTTP_CODE="$(curl -sSL -o "${WORK}/release.json" -w '%{http_code}' \
  --connect-timeout 15 --retry 3 "${RELEASE_URL}" 2>/dev/null || echo "000")"

case "${HTTP_CODE}" in
  200) RELEASE_JSON="$(cat "${WORK}/release.json")" ;;
  404)
    if [[ "${VERSION}" == "latest" ]]; then
      die "还没有发布任何版本。
   请维护者先上传安装包：见源码仓库 scripts/release_publish.sh
   发行页: https://github.com/${REPO}/releases" 1
    else
      die "找不到版本 v${VERSION}
   可用版本: https://github.com/${REPO}/releases" 1
    fi
    ;;
  000) die "无法连接 GitHub（检查网络或代理）" 1 ;;
  *)   die "访问 GitHub Releases 失败（HTTP ${HTTP_CODE}）" 1 ;;
esac

# 从 release JSON 抓 DMG 资产名与下载地址（避免依赖 jq）。
# GitHub 返回紧凑 JSON（字段间无换行），且不同 client 可能给 http/https，
# 所以先按逗号切段，再从中取 .dmg 结尾的 URL。
DMG_URL="$(printf '%s' "${RELEASE_JSON}" \
  | tr ',' '\n' | grep -o 'https\?://[^"]*\.dmg' | head -1 || true)"
[[ -n "${DMG_URL}" ]] || die "该版本没有 .dmg 资产"
DMG_NAME="$(basename "${DMG_URL}")"
RELEASE_TAG="$(printf '%s' "${RELEASE_JSON}" \
  | tr ',' '\n' | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//' || true)"

info "    版本: ${RELEASE_TAG:-${VERSION}}"
info "    资产: ${DMG_NAME}"

# 校验和：优先取同 Release 的 .sha256 资产
SHA_URL="${DMG_URL}.sha256"
EXPECTED_SHA="$(curl -fsSL --connect-timeout 10 "${SHA_URL}" 2>/dev/null | awk '{print $1}' | head -1 || true)"
[[ -n "${EXPECTED_SHA}" ]] && info "    校验: ${EXPECTED_SHA}" \
  || warn "该版本未提供 .sha256，跳过完整性校验"

if [[ ${DRY_RUN} -eq 1 ]]; then
  info ""
  info "（dry-run）计划如下："
  info "  下载 ${DMG_URL}"
  info "  安装到 ${DEST_DIR}/${APP_BUNDLE}"
  info "  清理 quarantine 标记（未公证也能运行）"
  [[ ${DO_LAUNCH} -eq 1 ]] && info "  安装后自动启动"
  exit 0
fi

# ── 2. 下载 ────────────────────────────────────────────────────
info "==> 2/6 下载安装包（约 866MB，视网速需数分钟）"
curl -fL --progress-bar --connect-timeout 20 --retry 3 --retry-delay 2 \
  "${DMG_URL}" -o "${WORK}/${DMG_NAME}" \
  || die "下载失败（网络中断？）"

ACTUAL_SHA="$(shasum -a 256 "${WORK}/${DMG_NAME}" | awk '{print $1}')"
if [[ -n "${EXPECTED_SHA}" ]]; then
  [[ "${ACTUAL_SHA}" == "${EXPECTED_SHA}" ]] \
    || die "校验失败：下载的文件不完整或已损坏
   期望 ${EXPECTED_SHA}
   实际 ${ACTUAL_SHA}"
  info "    ✅ 校验通过"
else
  info "    实际 sha256: ${ACTUAL_SHA}"
fi

# ── 3. 挂载并取出 .app ─────────────────────────────────────────
info "==> 3/6 挂载镜像"
MOUNT_POINT="${WORK}/mnt"
mkdir -p "${MOUNT_POINT}"
hdiutil attach "${WORK}/${DMG_NAME}" -mountpoint "${MOUNT_POINT}" \
  -nobrowse -quiet -noautoopen \
  || die "DMG 挂载失败（文件可能损坏）"
MOUNTED="${MOUNT_POINT}"

STAGED_APP="$(/usr/bin/find "${MOUNT_POINT}" -maxdepth 1 -name "*.app" -type d | head -1)"
[[ -n "${STAGED_APP}" ]] || die "DMG 内没有找到 .app"

STAGED_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${STAGED_APP}/Contents/Info.plist" 2>/dev/null || echo "?")"
info "    包版本: ${STAGED_VER}"

# ── 4. 安装 ────────────────────────────────────────────────────
info "==> 4/6 安装到 ${DEST_DIR}"
if ! mkdir -p "${DEST_DIR}" 2>/dev/null || [[ ! -w "${DEST_DIR}" ]]; then
  warn "${DEST_DIR} 不可写，改装到 ~/Applications"
  DEST_DIR="${HOME}/Applications"
  mkdir -p "${DEST_DIR}"
fi
TARGET="${DEST_DIR}/${APP_BUNDLE}"

if [[ -d "${TARGET}" ]]; then
  OLD_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${TARGET}/Contents/Info.plist" 2>/dev/null || echo "?")"
  info "    替换旧版本 ${OLD_VER} → ${STAGED_VER}"
  # 先退出运行中的实例，否则二进制被占用、模型缓存也释放不掉
  if pgrep -f "${TARGET}/Contents/MacOS/" >/dev/null 2>&1; then
    info "    退出正在运行的实例..."
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    sleep 2
    pkill -f "${TARGET}/Contents/MacOS/" >/dev/null 2>&1 || true
    sleep 1
  fi
  rm -rf "${TARGET}"
fi

# ditto 而非 cp -R：保留代码签名 seal 与扩展属性
ditto "${STAGED_APP}" "${TARGET}" || die "拷贝失败（磁盘空间是否足够？）"
info "    ✅ 已安装 ${TARGET}（${STAGED_VER}）"

# ── 5. 清 quarantine + 验签 ────────────────────────────────────
info "==> 5/6 代码签名与 Gatekeeper"
# curl 下载本不带 quarantine，这里仍显式清理一遍：
# 用户可能是先把包下到本地再跑脚本，路径上可能残留标记。
xattr -dr com.apple.quarantine "${TARGET}" 2>/dev/null || true
xattr -cr "${TARGET}" 2>/dev/null || true

if codesign --verify --deep --strict "${TARGET}" >/dev/null 2>&1; then
  AUTHORITY="$(codesign -dv --verbose=2 "${TARGET}" 2>&1 \
    | sed -n 's/^Authority=//p' | head -1)"
  info "    签名有效: ${AUTHORITY:-ad-hoc}"
else
  warn "签名校验未通过（ad-hoc 或文件被修改），首次启动可能需要右键→打开"
fi

if spctl -a -t exec "${TARGET}" >/dev/null 2>&1; then
  info "    Gatekeeper: ✅ 放行（已公证）"
else
  info "    Gatekeeper: 未公证 → 已清除隔离属性，可正常启动"
fi

# ── 6. 完成 ────────────────────────────────────────────────────
info "==> 6/6 完成"
info ""
info "✅ ${APP_NAME} ${STAGED_VER} 已安装"
info "   应用: ${TARGET}"
info "   数据: ${HOME}/.local-media-engine（模型约 10GB，首次启动按需下载）"
info ""
info "卸载: 重新运行本脚本并加 --uninstall"
info "      curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash -s -- --uninstall"

if [[ ${DO_LAUNCH} -eq 1 ]]; then
  info ""
  info "正在启动..."
  open -n "${TARGET}"
fi

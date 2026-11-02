# releasepkg

Knowcut 的安装包分发仓库。

**这个仓库只放安装脚本，安装包本体在 [Releases](../../releases)。**
（安装包约 866MB，超过 git 单文件 100MB 上限，不适合放进 git 历史。）

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/Y-B-S/releasepkg/main/install.sh | bash
```

装最新版。想装指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/Y-B-S/releasepkg/main/install.sh \
  | bash -s -- --version 0.2.1
```

先看看会做什么、不改系统：

```bash
curl -fsSL https://raw.githubusercontent.com/Y-B-S/releasepkg/main/install.sh \
  | bash -s -- --dry-run
```

卸载（保留你的素材数据）：

```bash
curl -fsSL https://raw.githubusercontent.com/Y-B-S/releasepkg/main/install.sh \
  | bash -s -- --uninstall
```

## 为什么用 curl 装而不是下载 DMG 双击

应用用 Developer ID 签名，但**尚未公证**。macOS 的 Gatekeeper 拦截只对
*带 `com.apple.quarantine` 标记*的文件生效，而这个标记是**浏览器下载时打上的**：

- 用**浏览器**下载 DMG → 带标记 → 双击被拦，"已损坏"或"无法验证开发者"
- 用 **curl** 下载 → 无标记 → 直接可用

安装脚本走 curl，并额外显式清理一次标记，所以不会遇到 Gatekeeper 提示。

如果你确实想手动下载 DMG：解开后右键 App → 打开，或执行
`xattr -dr com.apple.quarantine /Applications/konwcut.app`。

## 脚本会做什么

1. 从 Releases 解析版本与下载地址（也可 `--version` 指定）
2. 下载 DMG，用同 Release 的 `.sha256` 校验完整性（不匹配就中止）
3. 挂载并 `ditto` 安装到 `/Applications`（不可写则退回 `~/Applications`）
4. 退出正在运行的旧实例，替换为新版本
5. 清理 quarantine 标记，验证代码签名
6. 启动应用

## 系统要求

- macOS 11+，**Apple 芯片（arm64）**
- Intel Mac 不支持此包，需从源码构建

## 数据位置

- 应用：`/Applications/konwcut.app`
- 数据：`~/.local-media-engine/`（数据库、模型约 10GB、工作目录）
- 卸载不会删除数据；彻底清除：`rm -rf ~/.local-media-engine`

## 首次启动

内置 whisper-large-v3-turbo 模型（834MB），装完即可转录。其余模型
（bge / qwen / OCR 等）首次启动时后台按需下载，界面顶部有进度条。

## 发版（维护者）

在源码仓库构建后：

```bash
# 1. 打包
./scripts/bundle_app.sh
./scripts/make_dmg.sh          # → dist/konwcut-<ver>-arm64.dmg + .sha256

# 2. 上传到本仓库的 Releases
export GH_TOKEN=ghp_xxx        # 或先 brew install gh && gh auth login
./scripts/release_publish.sh   # 自动读版本、建 tag、传 dmg + sha256

# 3. 若安装脚本有更新，同步到本仓库
cp scripts/release_install.sh <本仓库>/install.sh && git commit -am "..." && git push
```

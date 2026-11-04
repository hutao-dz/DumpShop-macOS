# 第三方组件与致谢

## fairplay-decrypt

- 作者：**Ethan Arbuckle** 及项目贡献者。
- 上游：https://github.com/EthanArbuckle/fairplay-decrypt
- 基线版本：`bb09a61046f5c99eb1795589a307646df04b26d0`。
- 许可证：GPL-3.0，完整文本保留于 `vendor/fairplay-decrypt/LICENSE`。
- 使用范围：离线处理与设备端凭据提取；本项目提供 Python 独立助手、界面和任务封装。
- 本地适配涉及 USB SSH、账号授权定位与凭据校验。`UPSTREAM_REVISION` 是上游基线，并非声称本地适配源码与上游完全一致。

特别感谢作者将研究与实现公开，让本项目能够在其成果之上提供 Mac 桌面体验。原始代码及其贡献归上游作者所有。

源码中的 `static-key-table.bin` 和 `core4-word-table.bin` 是上游公开的算法静态数据表，与该基线文件一致；它们不是本机账号凭据。个人 `credential.bin`、设备身份文件及所有运行数据均未纳入公开源码。

## ipatool

- 上游：https://github.com/majd/ipatool
- 版本：v2.7.0，基线提交 `4484b55d366e177ae6c89758c61588712c572fad`。
- 许可证：MIT，完整文本位于 `vendor/ipatool/LICENSE`。
- 本地源码：`vendor/ipatool/`；主要修改补丁：`vendor/patches/ipatool-macos.patch`。
- 修改范围：地区钥匙串服务与状态目录隔离、商店地区输出、可选 TLS 1.2 兼容传输及对应测试。TLS 兼容模式保持证书校验。
- 国区组件由依赖脚本下载经哈希校验的官方发布包；其他地区使用此源码构建。港区另存一份助手以保留地区组件选择路径。
- 本源码包不附带任何现有助手的编译产物或账号身份。重新构建不保证与旧发布包逐字节相同。

Go 传递依赖声明与锁定信息保留在 `go.mod` 和 `go.sum`。

## 其他运行与构建组件

- Python `cryptography`：由 `vendor/fairplay-decrypt/requirements.txt` 声明，保留其自身许可证。
- PyInstaller：用于构建独立 Python 助手，遵循其 GPL 及打包例外条款；不将其代码声称为本项目原创。
- libimobiledevice、libusbmuxd、libplist、OpenSSL、sshpass 等：通过 `scripts/build_macos15_runtime.py` 从 `scripts/macos15-sources.json` 锁定源码独立编译，部署目标为 macOS 15，不复制本机 Homebrew 运行库。依赖许可证与来源清单随完整包放入 `Contents/Resources/licenses/native/`，不复制个人运行状态。
- 设备工具由本仓库的源码配合 Xcode iPhoneOS SDK 和 ldid 构建。

此前试验性 UnfairPlay 二进制未包含在本公开源码包中；客户端保留可选工具发现代码，不影响当前 fairplay-decrypt 构建路径。


完整安装包同时附带本项目许可证及 Python、cryptography、PyInstaller 的许可证（`vendor/runtime-licenses/`）。更新独立运行时依赖时，应同步核对对应版本的许可证。

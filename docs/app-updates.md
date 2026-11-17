# 应用内更新

RcHarness 使用 SwiftPM 固定的 Sparkle 2.10.1，沿用标准原生更新窗口，支持检查、显示更新、下载、签名校验和重启安装。首次下载和 Sparkle 应用内更新都使用 DMG；ZIP 作为备用下载格式保留。`AppUpdateModel` 只观察更新器状态及偏好；启动入口在截图模式返回之后，测试使用注入驱动，不联网、不替换真实应用。

更新配置、启动和检查失败的原因写入统一日志，不写入设置页版本信息区，也不追加主面板错误浮层；版本区始终保留上次检查时间。其他功能的操作通知保持不变。

更新候选按 `CFBundleShortVersionString`（appcast 的 `sparkle:shortVersionString`）的数字版本比较，仅线上展示版本高于本地时才允许进入 Sparkle 的更新流程；本地相同或更高时返回空候选，由 Sparkle 原生窗口统一提示已是最新版本。同一线上展示版本的多个候选再按内部构建号选择最新构建。此规则避免本地语义版本构建号与 CI 递增数字构建号混用时误报更新；不会将网络、解析或签名失败视为无更新，也不改变 Sparkle 的系统兼容性及安装校验。

## 更新源与签名

`build_app.sh` 根据 `RC_HARNESS_ARCH` 将目标架构的 HTTPS 更新源写入最终 `Info.plist`：

- Apple Silicon：`https://github.com/tokenzz-vip/RcHarness/releases/latest/download/appcast-arm64.xml`
- Intel：`https://github.com/tokenzz-vip/RcHarness/releases/latest/download/appcast-x86_64.xml`

源文件中的 URL 为 ARM 默认值；构建 Intel 包时会覆盖。两种架构使用相同公钥，但更新源与 DMG 完全分开，更新时保持已安装应用的架构。

更新 DMG 和 appcast 都使用 Ed25519 签名，应用在挂载和安装前验证更新包，并要求更新源签名。公钥提交在 `SUPublicEDKey` 中；私钥保存在本机登录钥匙串，Sparkle account 为 `vip.tokenzz.rcharness`。不要更换或删除此钥匙串项目；丢失私钥会影响后续更新。Apple Developer ID 签名、公证和 stapling 仍由发布流程完成。备用 ZIP 也保持 Apple 签名和公证，便于手动安装和排障。

SwiftPM 二进制制品同时包含框架与签名工具，构建脚本将框架及帮助程序嵌入应用、裁剪为单一目标架构，再使用本次构建身份由内到外签名。无需单独安装 Sparkle。SwiftPM 的 `Package.resolved` 应一并提交。

## 首次配置发布

GitHub 仓库需要新增 `SPARKLE_PRIVATE_KEY` Actions secret。本次开发已在上述 account 中生成密钥，导出时不要将密钥打印到终端或写入仓库。可在准备好上传时运行：

```bash
swift package resolve
keyfile="$(mktemp -t rcharness-sparkle-key)"
chmod 600 "$keyfile"
trap 'rm -f "$keyfile"' EXIT
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account vip.tokenzz.rcharness -x "$keyfile"
gh secret set SPARKLE_PRIVATE_KEY --repo tokenzz-vip/RcHarness < "$keyfile"
```

使用安全方式备份此密钥。新机器上可用同一工具的 `-f` 选项导入。用 `generate_keys --account vip.tokenzz.rcharness -p` 查看公钥，并确认与应用内公钥一致。

## 每次发布

发布 workflow 的矩阵分别在 ARM 与 Intel runner 上测试、构建、签名和公证，创建正式 Release 前要求所有签名 secret 就绪。每个架构完成应用公证和 staple 后生成最终 DMG 与备用 ZIP，再使用相同的 Developer ID Application 身份签名 DMG、校验签名、单独公证和 staple，并通过 `spctl --assess --type open --context context:primary-signature` 检查 DMG，最后运行 `scripts/generate_update_feed.sh`。脚本从最终 DMG 读取构建号、展示版本和最低系统版本，生成签名更新源，并校验目标架构、包内更新源、下载地址、DMG 长度、版本及签名；任一步失败不会发布 Release。两个构建都成功后，发布任务合并并验证 SHA256SUMS，将两个 DMG、两个备用 ZIP、两个 appcast 和 SHA256SUMS 作为同一 Release 的附件一起发布。

`CFBundleVersion` 使用现有 workflow 的 `github.run_number`，必须保持递增，避免重建 workflow 后重置。展示版本遵循 `vMAJOR.MINOR.PATCH` 标签。每次正式发布都必须同时附带两个架构的 appcast，否则对应的 latest 更新入口会失效。每个架构提供独立全量更新，不生成增量包。

发布包分别命名为 `RcHarness-v版本号-macos-arm64.dmg` 和 `RcHarness-v版本号-macos-x86_64.dmg`；备用下载包沿用同名 `.zip` 后缀。最低系统保持 macOS 14。DMG 和 ZIP 内的应用都叫 `RcHarness.app`，主程序、HAL 驱动及所有 Sparkle 辅助进程均只含该包的目标架构。DMG 同时包含“应用程序”快捷方式，供首次安装使用。

旧版 Universal 应用仍读取 `appcast.xml`，本次拆分后不再发布该公共源。用户需手动下载一次对应架构的包覆盖旧应用，配置保持原位置；后续更新使用各自独立更新源。Apple Silicon 用户应下载 arm64 包；在 Rosetta 下使用 x86_64 包会继续收到 Intel 更新。

本地可对专用发布目录运行：

```bash
# 每个目录至少放对应架构的最终 DMG；ZIP 可作为备用资产一并保留。
bash scripts/generate_update_feed.sh /path/to/arm64-assets v0.7.1 tokenzz-vip/RcHarness arm64
bash scripts/generate_update_feed.sh /path/to/x86_64-assets v0.7.1 tokenzz-vip/RcHarness x86_64
```

本地默认从上述钥匙串 account 读私钥；CI 从 `SPARKLE_PRIVATE_KEY` 通过标准输入传递，私钥不出现在命令参数中。

## 虚拟麦克风同步更新

HAL 组件仍随应用放在 `Contents/PlugIns/RcHarnessMicrophone.driver`。新应用启动时，若系统已安装组件且其 `CFBundleVersion` 小于随包版本，则自动进入现有管理员授权安装流程。相同版本不重复安装，系统组件版本较新时不降级，未安装时不自动安装。修改驱动代码或共享协议时，必须提高 `Drivers/RcHarnessMicrophone/Info.plist` 的 `CFBundleVersion`，展示版本按需要同步提高。

安装前释放语音会话与输出，暂时禁用重复组件操作；授权后将随包驱动复制到系统临时目录，核对精确代码签名后替换旧组件，并重启 coreaudiod。应用更新和系统组件更新是两次独立操作；取消授权或安装失败时，新应用保留组件待更新提示及连接页重试入口，下次启动再次检查。

## 验证边界

单元测试覆盖检查门禁、偏好同步、失败重试，以及驱动版本比较。发布脚本校验真实最终 DMG 和签名更新源；设置页通过 `--render-settings` 检查布局。正式启用前，应使用两个递增构建完成一次真实升级验收：旧版检查到新版、下载、重启后版本变更、配置保留，以及驱动版本递增时的授权和重试。未发布的新版本无法通过线上 latest 地址完成这一验收。

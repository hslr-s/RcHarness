# 组合动作页切换性能

2026-11-16，本机 Apple Silicon。使用隔离的 UserDefaults suite 和默认 210 个组合动作，不读取或修改真实用户配置。

计时通过真实 `RemoteDashboardView` 在最小窗口尺寸下从「设置」切入「组合动作」，覆盖 `model.page` 修改和 `NSHostingView.layoutSubtreeIfNeeded()`，每组连续测量 5 次。修改步骤后先 flush，避免将待保存编辑混入布局计时。

## 左侧动作列表（Debug）

| 指标 | 修改前 | 左侧延迟加载后 |
| --- | ---: | ---: |
| 首次切入 | 406.13 ms | 122.17 ms |
| 5 次中位耗时 | 285.31 ms | 80.72 ms |

左侧列表原先使用 `VStack`，每次进入页面都会创建并布局全部行。改用 `LazyVStack`，按可见区域创建行，中位耗时减少约 72%。列表数据、筛选、选择和独立滚动保持原有行为。

## 右侧步骤编辑器（Release）

首个动作分别使用 1、12、50、100 个相同快捷键步骤，保持左侧 210 个动作和相同切页路径。优化前的右侧使用 `VStack`，优化后使用 `LazyVStack`。下表为 5 次切页的中位耗时：

| 右侧步骤数 | 优化前 | 完成验证后的实现 |
| --- | ---: | ---: |
| 1 | 86.81 ms | 75.53 ms |
| 12 | 199.48 ms | 86.55 ms |
| 50 | 621.85 ms | 86.62 ms |
| 100 | 未测量 | 89.46 ms |

50 步场景中位耗时减少约 86%。主要收益来自不再一次性创建屏外步骤的原生控件；单步骤的小幅差异受运行环境影响，不据此承诺普遍提速。另一个对照中，将左侧动作从 210 减到 1 后，单步骤场景仍需约 75.20 ms，因此继续优化左侧数据数量的收益有限。

以上测量仅覆盖主线程同步布局，不包含屏幕呈现延迟，不能代表所有设备和配置的实际交互延迟。

## 回归验证

`MacrosEditorInteractionTests` 新增 8 项真实 SwiftUI／AppKit 交互测试，使用隔离配置，覆盖：

- 50 步动作初次打开仅创建附近的原生动作控件；该测试在旧实现上创建了全部 50 个控件并失败，新实现通过，不依赖机器耗时阈值。
- 长动作末尾连续添加三步，新增步骤及其下方按钮仍可见。
- 混合高度的普通按键、快速删除、录制快捷键、嵌套动作和打开应用步骤；删除屏外首步后编辑末步，验证仍按原步骤 ID 保存，其他步骤不变，再实际点击删除末步并添加。
- 切换动作后从顶部显示；清空步骤后可重新添加；删除选中动作后打开剩余动作。
- 100 步混合高度动作，在最小窗口内容尺寸和深色外观下滚动到末尾后添加，固定名称编辑区不越界。
- 录制步骤滚动移出并被回收后取消未完成录制，迟到释放不生效；返回后可以重新录制并写回正确步骤。
- 录制完成回调已排队、但对应步骤在回调执行前被删除时，不将录制结果写到下一行。
- 录制途中切换动作取消本次录制，两个动作的内容均不被改变。

录制交互测试在测试进程内临时注入前台状态，并由测试窗口提供局部焦点；每个 fixture 关闭时还原查询实现。实际 SwiftUI 控件、绑定、录制会话和延迟回调均使用生产代码，键盘事件仅交给测试会话，不向真实会话投递。测试不依赖物理显示器或从其他应用抢占焦点，不代表真实桌面焦点的端到端验收。

验证结果：

- `scripts/test_all.sh`：508 项测试、零失败、3 项跳过；HAL 驱动 ASan/UBSan 通过；音频异常保护及音频探针 12 次会话均通过。
- 跳过项为两项默认关闭的性能基准，以及显示器休眠时无法验证真实键盘焦点的既有 `HarnessSwitcherTests.testControllerRepeatedlyPresentsAVisiblePanelFromTheBackground`。本次新增 8 项测试全部执行通过。
- Release 构建重复执行新增 8 项交互测试及 1／12／50／100 步性能基准，全部通过。
- 使用 `--render-settings` 导出普通外观和深色窄窗口页面并检查；另检查混合高度长动作编辑后的截图和深色窄窗口的末尾新增步骤截图，布局正常。

## 复测

默认单步骤基准：

```bash
RC_HARNESS_MACROS_BENCHMARK=/tmp/rcharness-macros.json \
  swift test --filter MacrosLayoutTests.testMacroPageNavigationBenchmark
```

Release 长动作基准：

```bash
RC_HARNESS_MACROS_BENCHMARK=/tmp/rcharness-macros-50.json \
RC_HARNESS_MACROS_BENCHMARK_STEPS=50 \
RC_HARNESS_MACROS_BENCHMARK_MAX_MS=150 \
  swift test -c release --filter MacrosLayoutTests.testMacroPageNavigationBenchmark
```

步骤数支持 0–100。基准默认跳过；显式运行时输出原始耗时及中位数 JSON，检查中位耗时低于显式预算（默认 100 ms），阈值用于本机复测，会受机器负载和系统版本影响。常规交互测试不使用耗时阈值。

```bash
swift test --filter MacrosEditorInteractionTests
scripts/test_all.sh
```

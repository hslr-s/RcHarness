#!/usr/bin/env bash
# 开发期一键编译并运行 RcHarness。
# 直接运行 SwiftPM 可执行文件，不打包 .app、不签名，适合快速验证 UI 与手势逻辑。
# 需要 HAL 虚拟麦克风、完整资源或正式签名时，改用 scripts/build_app.sh。
#
# 用法：
#   scripts/run_dev.sh                              # 编译并启动菜单栏 App
#   scripts/run_dev.sh --render                     # 导出设置页截图到 /tmp/rcharness-settings
#   scripts/run_dev.sh --render ./shots --dark --narrow
#   scripts/run_dev.sh --no-build                   # 跳过编译，直接跑现有二进制
#   scripts/run_dev.sh --no-build --render          # 跳过编译并导出截图
#   scripts/run_dev.sh -- --harness chatgpt          # 透传任意 App 参数
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${RC_HARNESS_CONFIGURATION:-debug}"
case "${CONFIG}" in debug|release) ;; *) echo "Unknown configuration: ${CONFIG}" >&2; exit 1 ;; esac

SKIP_BUILD=0
if [[ "${1:-}" == "--no-build" ]]; then
  SKIP_BUILD=1
  shift
fi

if [[ "${1:-}" == "--render" ]]; then
  OUT="${2:-/tmp/rcharness-settings}"
  shift
  if [[ $# -gt 0 ]]; then shift; fi
  set -- --render-settings "${OUT}" "$@"
  echo "==> 截图输出目录: ${OUT}"
fi

if [[ "${SKIP_BUILD}" -eq 1 ]]; then
  echo "==> 跳过编译（使用现有二进制）"
else
  echo "==> swift build (-c ${CONFIG})"
  swift build --package-path "${ROOT}" -c "${CONFIG}"
fi

BIN="$(swift build --package-path "${ROOT}" --show-bin-path -c "${CONFIG}")/RcHarness"
if [[ ! -x "${BIN}" ]]; then
  echo "可执行文件不存在: ${BIN}" >&2
  exit 1
fi

# SPM 可执行文件不会自动携带 bundle 资源；把遥控器图片放到同级目录，
# 供 Bundle.main.resourceURL 加载。
BIN_DIR="$(cd "$(dirname "${BIN}")" && pwd)"
for asset in "${ROOT}"/assets/app/*.png; do
  if [[ -f "${asset}" ]]; then
    cp -f "${asset}" "${BIN_DIR}/$(basename "${asset}")"
  fi
done

echo "==> 启动 ${BIN} $*"
exec "${BIN}" "$@"

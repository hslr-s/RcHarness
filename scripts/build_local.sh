#!/usr/bin/env bash
set -euo pipefail

# 本机一键构建：加载 ~/.zshrc 里的签名身份，构建并校验 App 与 HAL 驱动签名。
# 用法：scripts/build_local.sh [输出目录/RcHarness.app]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${ROOT}/.build/RcHarness.app}"

fail() { echo "build_local: $*" >&2; exit 1; }

# 非交互 shell 未继承 RC_HARNESS_LOCAL_SIGNING_IDENTITY 时，借 zsh -ic 加载一次。
if [[ -z "${RC_HARNESS_LOCAL_SIGNING_IDENTITY:-}" && -z "${RC_HARNESS_ENV_LOADED:-}" ]]; then
  export RC_HARNESS_ENV_LOADED=1
  exec /bin/zsh -ic 'exec "$@"' zsh "$0" "$@"
fi

IDENTITY="${RC_HARNESS_LOCAL_SIGNING_IDENTITY:-}"
[[ -n "${IDENTITY}" ]] || fail "未设置 RC_HARNESS_LOCAL_SIGNING_IDENTITY，请在 ~/.zshrc 中配置后重试。"
[[ "${IDENTITY}" != "-" ]] || fail "签名身份不能是 '-'，不允许 ad-hoc 回退。"

if ! security find-identity -v -p codesigning | grep -Fq "\"${IDENTITY}\""; then
  fail "签名身份不在 security find-identity -v -p codesigning 的有效列表中：${IDENTITY}"
fi

"${ROOT}/scripts/build_app.sh" "${OUT}" local

APP_AUTHORITY="$(codesign -dvvv "${OUT}" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
[[ "${APP_AUTHORITY}" == "${IDENTITY}" ]] || fail "App 签名身份不匹配：${APP_AUTHORITY}"

DRIVER="${OUT}/Contents/PlugIns/RcHarnessMicrophone.driver"
[[ -d "${DRIVER}" ]] || fail "找不到随包 HAL 驱动：${DRIVER}"
codesign --verify --deep --strict "${DRIVER}"
DRIVER_AUTHORITY="$(codesign -dvvv "${DRIVER}" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
[[ "${DRIVER_AUTHORITY}" == "${IDENTITY}" ]] || fail "HAL 驱动签名身份不匹配：${DRIVER_AUTHORITY}"

echo "构建完成：${OUT}"
echo "签名身份：${IDENTITY}"
echo "App 与 HAL 驱动均已通过 codesign --verify --deep --strict"

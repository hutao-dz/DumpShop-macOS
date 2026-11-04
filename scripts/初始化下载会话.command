#!/bin/zsh
set -euo pipefail

APP_PATH="${DUMPSHOP_APP_PATH:-/Applications/砸壳工坊.app}"
IPATOOL="$APP_PATH/Contents/Resources/bin/ipatool-arm64"
STORE_SCRIPT="$APP_PATH/Contents/Resources/engine/store.py"

if [[ ! -x "$IPATOOL" ]]; then
  SCRIPT_DIR="${0:A:h}"
  for candidate in \
    "$SCRIPT_DIR/砸壳工坊.app/Contents/Resources/bin/ipatool-arm64" \
    "$SCRIPT_DIR/../outputs/砸壳工坊.app/Contents/Resources/bin/ipatool-arm64"
  do
    if [[ -x "$candidate" ]]; then
      APP_PATH="${candidate%/Contents/Resources/bin/ipatool-arm64}"
      IPATOOL="$candidate"
      STORE_SCRIPT="$APP_PATH/Contents/Resources/engine/store.py"
      break
    fi
  done
fi

if [[ ! -x "$IPATOOL" ]]; then
  echo "找不到砸壳工坊.app。请先把应用拖进“应用程序”，再运行此脚本。"
  read -k 1 "?按任意键关闭…"
  exit 1
fi

CACHE_ROOT="${DUMPSHOP_SUPPORT_ROOT:-$HOME/Library/Application Support/DumpShop}"

echo "砸壳工坊 - 一次性下载会话初始化"
echo
echo "这里只初始化电脑读取 App Store 加密包所需的持久会话。"
echo "每个地区使用独立会话，互不覆盖。"
echo "成功后会保存在 macOS 钥匙串，应用本身不再显示任何登录表单。"
echo

profile="cn"
region_name="国区"
echo "请选择要登录的 App Store 地区："
echo "  1) CN 国区"
echo "  2) US 美区"
echo "  3) JP 日区"
echo "  4) HK 港区"
echo "  5) TW 台区"
echo
read -r "region_choice?地区编号 [1-5]（默认 1）: "
case "${region_choice:-1}" in
  2) profile="us"; region_name="美区" ;;
  3) profile="jp"; region_name="日区" ;;
  4) profile="hk"; region_name="港区" ;;
  5) profile="tw"; region_name="台区" ;;
  1|"") profile="cn"; region_name="国区" ;;
  *) echo "地区编号无效，已取消。"; exit 1 ;;
esac

if [[ "$profile" != "cn" ]]; then
  PROFILE_IPATOOL="$APP_PATH/Contents/Resources/bin/ipatool-profile-arm64"
  if [[ -x "$PROFILE_IPATOOL" ]]; then
    IPATOOL="$PROFILE_IPATOOL"
  else
    echo "应用包内缺少多地区组件，请重新安装完整应用包后再试。"
    exit 1
  fi
  if ! "$IPATOOL" --version | /usr/bin/grep -q 'dumpshop-profiles'; then
    echo "下载组件不支持独立地区账号，请重新安装完整应用包。"
    exit 1
  fi
fi

if [[ "$profile" == "cn" ]]; then
  state_dir="$CACHE_ROOT/ipatool-state"
else
  state_dir="$CACHE_ROOT/ipatool-state/profiles/$profile"
fi
export XDG_DATA_HOME="$state_dir"
export XDG_STATE_HOME="$state_dir"
export IPATOOL_PROFILE="$profile"
if [[ "$profile" == "hk" ]]; then
  IPATOOL="$APP_PATH/Contents/Resources/bin/ipatool-hk-arm64"
  if [[ ! -x "$IPATOOL" ]]; then
    echo "缺少港区下载组件，请重新构建完整应用。"
    exit 1
  fi
  export DUMPSHOP_TLS12=1
  export GODEBUG="${GODEBUG:+$GODEBUG,}tlsmlkem=0,http2client=0"
fi
mkdir -p "$XDG_DATA_HOME"

echo
echo "本次地区：${region_name}（${profile}）"
echo "会话目录：${XDG_DATA_HOME}"
echo

email=""
while [[ -z "${email//[[:space:]]/}" ]]; do
  read -r "email?Apple ID（邮箱）: "
done

echo
echo "接下来由 ipatool 请求密码；输入内容不会显示，也不会写入日志。"
echo "如果终端询问双重认证验证码，请按提示直接输入。"
echo

PYTHON="$APP_PATH/Contents/Resources/bin/engine-runtime"
if [[ ! -x "$PYTHON" ]]; then
  PYTHON="$(command -v python3 || true)"
fi
if [[ -f "$STORE_SCRIPT" ]]; then
  if [[ -n "$PYTHON" ]]; then
    echo "正在准备 App Store 签名组件，首次可能需要一两分钟…"
    "$PYTHON" "$STORE_SCRIPT" \
      --cache-root "$CACHE_ROOT" \
      --ipatool "$IPATOOL" \
      --profile "$profile" \
      warm || echo "签名组件预取未完成，ipatool 会继续尝试。"
    echo
  fi
fi

echo "请使用 ${region_name} 对应的 Apple ID 登录。"
echo
"$IPATOOL" auth login --email "$email"

echo
echo "${region_name}会话检查："
if [[ -n "$PYTHON" && -f "$STORE_SCRIPT" ]]; then
  "$PYTHON" - "$STORE_SCRIPT" "$IPATOOL" "$CACHE_ROOT" "$profile" <<'PY'
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("store", sys.argv[1])
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)
info = store.auth_info(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
if not info.get("logged_in"):
    print(info.get("error") or "会话检查失败")
    sys.exit(1)
print("下载会话已就绪：" + (info.get("email") or info.get("name") or ""))
PY
else
  echo "缺少 Python，暂时无法确认账号地区。请打开应用检查会话状态。"
  exit 1
fi

echo
echo "初始化完成。回到“砸壳工坊”后，把主界面地区切换到 ${region_name}，"
echo "再为此下载账号选择同账号的解密凭据，即可下载和解密。"
echo "新增 Apple 账号需要在越狱 iPhone 上安装该账号取得的 App，提取一次凭据。"
read -k 1 "?按任意键关闭…"

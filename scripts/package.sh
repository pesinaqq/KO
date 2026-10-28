#!/usr/bin/env bash
# 组装发行目录：二进制 + 随包运行时 + bridge
# 用法: ./scripts/package.sh [platform]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os" in
    darwin) [[ "$arch" == "arm64" ]] && echo "macos-arm64" || echo "macos-x64" ;;
    linux)  [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && echo "linux-arm64" || echo "linux-x64" ;;
    mingw*|msys*|cygwin*)
      [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && echo "windows-arm64" || echo "windows-x64"
      ;;
  esac
}

PLAT="${1:-$(detect_platform)}"
DIST="$ROOT/dist/KOTV-$PLAT"
RUNTIME_SRC="$ROOT/runtime"
# 版本号：优先环境变量 KOTV_VERSION / VERSION，去掉前导 v
VERSION="${KOTV_VERSION:-${VERSION:-0.1.0}}"
VERSION="${VERSION#v}"

echo "platform=$PLAT"
echo "dist=$DIST"
echo "version=$VERSION"

if [[ ! -d "$RUNTIME_SRC" || ! -d "$RUNTIME_SRC/bridge" ]]; then
  echo "runtime missing, running prepare-runtime.sh $PLAT ..."
  "$ROOT/scripts/prepare-runtime.sh" "$PLAT"
fi

rm -rf "$DIST"
mkdir -p "$DIST/runtime"

echo "building binary..."
case "$PLAT" in
  macos-arm64)  export GOOS=darwin  GOARCH=arm64 ;;
  macos-x64)    export GOOS=darwin  GOARCH=amd64 ;;
  linux-arm64)  export GOOS=linux   GOARCH=arm64 ;;
  linux-x64)    export GOOS=linux   GOARCH=amd64 ;;
  windows-x64)    export GOOS=windows GOARCH=amd64 ;;
  windows-arm64)  export GOOS=windows GOARCH=arm64 ;;
esac
export CGO_ENABLED=1
BIN="KOTV"
[[ "$GOOS" == "windows" ]] && BIN="KOTV.exe"

# Windows：QuickJS(CGO) Win7 —— MSVCRT MinGW + 静态链 MinGW 运行时 + 链接子系统 6.01
# QuickJS / crawshaw 等会用 pthread；crawshaw 还显式 #cgo LDFLAGS: -lwinpthread，
# 即便 win32 线程模型也会动态依赖 libwinpthread-1.dll → 必须强制静态链。
# 勿在 CGO_*FLAGS 里再 -D_WIN32_WINNT：go-libutp 等依赖已带 -D_WIN32_WINNT=0x600，会刷 redefine 警告。
# 勿用 UCRT 工具链，否则 Win7 上常见 Can't find dependent libraries / 缺 api-ms-win-crt-*
if [[ "$PLAT" == "windows-x64" ]]; then
  export CC="${CC:-gcc}"
  export CXX="${CXX:-g++}"
  export CGO_CFLAGS="${CGO_CFLAGS:--O2}"
  export CGO_CXXFLAGS="${CGO_CXXFLAGS:--O2}"
  if ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: Windows 打包需要 MinGW gcc（建议 MSVCRT + win32 线程模型）" >&2
    exit 1
  fi
  # 探测是否误用 UCRT 工具链
  if "$CC" -v 2>&1 | grep -qi 'ucrt'; then
    echo "WARNING: 当前 gcc 像是 UCRT 工具链，Win7 上 QuickJS/CGO 可能无法加载。请改用 msvcrt MinGW。" >&2
  fi
  # 删掉 winpthread 的 DLL import lib，迫使 -lwinpthread（含 crawshaw 注入的）走 .a 静态库
  mingw_root="$("$CC" -print-sysroot 2>/dev/null || true)"
  if [[ -z "$mingw_root" || "$mingw_root" == "/" ]]; then
    mingw_root="$(dirname "$(dirname "$(command -v "$CC")")")"
  fi
  while IFS= read -r dll_a; do
    echo "[cgo] remove DLL import to force static: $dll_a"
    rm -f "$dll_a"
  done < <(find "$mingw_root" -name 'libwinpthread.dll.a' -o -name 'libpthread.dll.a' 2>/dev/null || true)
  # -l:libwinpthread.a 明确静态；再加 -Bstatic 兜底（QuickJS pthread / crawshaw）
  WIN_PTHREAD_LD="-Wl,-Bstatic -l:libwinpthread.a -Wl,-Bdynamic"
  export CGO_LDFLAGS="${CGO_LDFLAGS:--static-libgcc -static-libstdc++ ${WIN_PTHREAD_LD}}"
  echo "[cgo] Win7 QuickJS flags: CC=$CC CGO_CFLAGS=$CGO_CFLAGS CGO_LDFLAGS=$CGO_LDFLAGS"
  if "$CC" -v 2>&1 | grep -qi 'Thread model: posix'; then
    echo "[cgo] gcc Thread model=posix（仍强制静态 winpthread）"
  fi
fi

# Windows ARM64：必须用 aarch64 工具链（llvm-mingw）。x86_64 gcc 会在 runtime/cgo 的 gcc_arm64.S 报错。
if [[ "$PLAT" == "windows-arm64" ]]; then
  if [[ -z "${CC:-}" ]]; then
    if command -v aarch64-w64-mingw32-clang >/dev/null 2>&1; then
      export CC=aarch64-w64-mingw32-clang
      export CXX="${CXX:-aarch64-w64-mingw32-clang++}"
    elif command -v clang >/dev/null 2>&1; then
      export CC=clang
      export CXX="${CXX:-clang++}"
    fi
  fi
  export CGO_CFLAGS="${CGO_CFLAGS:--O2}"
  export CGO_CXXFLAGS="${CGO_CXXFLAGS:--O2}"
  echo "[cgo] Windows ARM64 flags: CC=${CC:-} CXX=${CXX:-}"
  if [[ -z "${CC:-}" ]] || ! command -v "$CC" >/dev/null 2>&1; then
    echo "ERROR: windows-arm64 需要 aarch64-w64-mingw32-clang（llvm-mingw），不能用 x86_64 gcc" >&2
    exit 1
  fi
  # 粗检：若 CC 是 gcc 且 --version 像 x86_64，基本会炸
  if "$CC" --version 2>&1 | head -5 | grep -qiE 'x86_64-w64-mingw32|Target: x86_64'; then
    echo "ERROR: CC=$CC 看起来是 x86_64 工具链，无法编译 windows/arm64 CGO" >&2
    exit 1
  fi
fi

# Windows：嵌入 .ico 到 exe（Explorer / 任务栏）
if [[ "$PLAT" == windows-* ]]; then
  "$ROOT/scripts/gen-windows-icons.sh"
  "$ROOT/scripts/gen-win-syso.sh" "$PLAT" || true
fi

# ModuleLoader CGO 依赖 quickjs-go 头文件（qjsinc/ 不入库，构建前生成）
echo "generating spider qjsinc headers..."
(cd "$ROOT/internal/spider" && env -u GOOS -u GOARCH -u CC -u CXX CGO_ENABLED=0 go run gen_qjsinc.go)

LDFLAGS="-s -w -X github.com/bobo/KOTV/internal/update.CurrentVersion=${VERSION}"
if [[ "$PLAT" == "windows-x64" ]]; then
  # 最终链接：静态 MinGW 运行时 + 强制静态 winpthread（crawshaw/QuickJS）+ Win7 子系统
  EXTLD="-static-libgcc -static-libstdc++ ${WIN_PTHREAD_LD:--Wl,-Bstatic -l:libwinpthread.a -Wl,-Bdynamic} -Wl,--subsystem,windows:6.01"
  (cd "$ROOT" && go build -ldflags "${LDFLAGS} -extldflags '${EXTLD}'" -o "$DIST/$BIN" ./cmd/engine)
else
  (cd "$ROOT" && go build -ldflags "$LDFLAGS" -o "$DIST/$BIN" ./cmd/engine)
fi

if [[ "$PLAT" == "windows-x64" ]]; then
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -File "$ROOT/scripts/check-win7-deps.ps1" -Exe "$DIST/$BIN" || true
  elif command -v powershell >/dev/null 2>&1; then
    powershell -File "$ROOT/scripts/check-win7-deps.ps1" -Exe "$DIST/$BIN" || true
  elif command -v objdump >/dev/null 2>&1; then
    echo "[cgo] objdump dependents (manual Win7 check):"
    objdump -p "$DIST/$BIN" 2>/dev/null | grep -i "DLL Name" || true
  fi
fi

echo "copying runtime..."
# macOS 用 ditto，避免 cp 丢 dylib/符号链接（曾出现 jre/lib 缺失 → bridge EOF）
if [[ "$(uname -s)" == "Darwin" ]] && command -v ditto >/dev/null 2>&1; then
  mkdir -p "$DIST/runtime"
  ditto "$RUNTIME_SRC" "$DIST/runtime"
else
  cp -a "$RUNTIME_SRC/." "$DIST/runtime/"
fi
# 不进发行包：外部 mpv、残留 libmpv、空的 lib/ 及无用目录
rm -rf "$DIST/runtime/mpv" "$DIST/runtime/vlc" "$DIST/runtime/libvlc" "$DIST/runtime/lib" "$DIST/runtime/libmpv"

# bridge 始终重新构建，避免发行包混入旧 ABI。
mkdir -p "$RUNTIME_SRC/bridge" "$DIST/runtime/bridge"
echo "[bridge] building..."
(cd "$ROOT" && ./bridge/build.sh)
if [[ ! -f "$ROOT/bridge/spider-bridge.jar" ]]; then
  echo "ERROR: bridge/spider-bridge.jar 不存在，无法打包 JAR 爬虫支持" >&2
  exit 1
fi
cp -f "$ROOT/bridge/spider-bridge.jar" "$RUNTIME_SRC/bridge/"
cp -f "$ROOT/bridge/spider-bridge.jar" "$DIST/runtime/bridge/"

# updater（若已构建）
if [[ -f "$ROOT/cmd/updater/updater" ]]; then
  cp "$ROOT/cmd/updater/updater" "$DIST/"
elif [[ -f "$ROOT/cmd/updater/updater.exe" ]]; then
  cp "$ROOT/cmd/updater/updater.exe" "$DIST/"
fi

echo "verifying runtime..."
"$ROOT/scripts/verify-runtime.sh" "$DIST/runtime" "$PLAT"

# macOS：再打 .app + DMG（系统显示名 KO影视）
if [[ "$PLAT" == macos-* ]]; then
  "$ROOT/scripts/macos-app.sh" "$PLAT" "$DIST"
fi

cat > "$DIST/README.txt" <<EOF
KO影视 / KOTV 发行包 ($PLAT)

目录:
  $BIN              主程序（内嵌 QuickJS，JS 爬虫无需额外运行时）
  runtime/          捆绑运行时
    jre/            Liberica 21（JAR 爬虫，常驻 bridge 进程）
    python/         CPython 3.14（Python 爬虫）
    chromium/       嗅探/解析（Win x64=Win7 REWORK 最新；Win ARM64=最新 snapshot）
    ffmpeg/         FFmpeg（Windows 为 7.0）
    bridge/         spider-bridge.jar

macOS 另产出:
  dist/KO影视.app
  dist/KO影视-$PLAT.dmg

Windows 运行时（Win7 尽力兼容）：
  JRE = 全平台 Liberica 21；Win amd64 另加 api-ms-win-core-path（Win7 SP1+）
  Python = adang1345/PythonVista embed
  Chromium = x64: 109（snapshot 回退）；ARM64: Win_Arm64 最新（CFT 无 win-arm64 时）
  FFmpeg = Gyan 7.0
  页内 MPV = Flutter media_kit 自带（不进 runtime/）
  页内 FVP = Flutter fvp/libmdk（备选）
  外部 MPV/IINA = 系统安装或 PATH
  CGO/QuickJS = MinGW MSVCRT win32-seh + 子系统 Win7(6.01) + static-libgcc（posix 则再静态 winpthread）
               CI 用 scripts/check-win7-deps.ps1 拒绝 UCRT / libgcc_s / libwinpthread

启动:
  ./$BIN
  遥控页: http://127.0.0.1:9978/
  Web 包（引擎+webapp 同端口）见 scripts/package-flutter-web.sh / CI「Flutter Web」

默认播放核心为「页内 MPV」（innie#mpv）；桌面可切「页内 FVP」（innie#fvp）。
外部 MPV/IINA/VLC 需系统安装或 PATH，发行包不捆绑外部播放器。

环境变量(可选):
 KOTV_RUNTIME=/path/to/runtime 覆盖运行时根目录

开发准备运行时:
  ./scripts/prepare-runtime.sh $PLAT
EOF

echo "done: $DIST"
du -sh "$DIST" || true
echo "runtime components:"
ls -1 "$DIST/runtime" 2>/dev/null || true

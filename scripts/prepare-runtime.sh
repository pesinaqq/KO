#!/usr/bin/env bash
# 下载并准备随包运行时：JRE + Python + Chromium + ffmpeg
# 用法:
# ./scripts/prepare-runtime.sh # 当前主机平台
# ./scripts/prepare-runtime.sh macos-arm64 # 指定平台（会覆盖 runtime/）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.runtime-cache"
OUT_ROOT="$ROOT/runtime"

PYTHON_VER="3.14.7"
PYTHON_TAG="20260807"
PYTHON_MM="${PYTHON_VER%.*}"   # 3.14
PYTHON_ABI="cp${PYTHON_MM//./}" # cp314
JRE_VER="21"                 # 全平台统一 BellSoft Liberica feature version
LIBERICA_FEATURE="$JRE_VER"

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os" in
    darwin)
      [[ "$arch" == "arm64" ]] && echo "macos-arm64" || echo "macos-x64"
      ;;
    linux)
      [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && echo "linux-arm64" || echo "linux-x64"
      ;;
    mingw*|msys*|cygwin*)
      [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && echo "windows-arm64" || echo "windows-x64"
      ;;
 *)
      echo "unsupported OS: $os" >&2
      exit 1
      ;;
  esac
}

# Actions / 本机 gh 登录后可用；带 token 可避开 GitHub API 匿名 60/h 限流。
_github_token() {
  printf '%s' "${GITHUB_TOKEN:-${GH_TOKEN:-}}"
}

download() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" && -s "$dest" ]]; then
    echo "  cache hit: $(basename "$dest")"
    return
  fi
  echo "  download: $url"
  # Adoptium / GitHub 偶发 HTTP/2 帧错误，强制 HTTP/1.1 并加重试
  local i partial="${dest}.partial.$$"
  local -a curl_auth=()
  local tok
  tok="$(_github_token)"
  if [[ -n "$tok" && ( "$url" == https://api.github.com/* || "$url" == https://github.com/* ) ]]; then
    curl_auth=(-H "Authorization: Bearer ${tok}" -H "X-GitHub-Api-Version: 2022-11-28")
  fi
  for i in 1 2 3 4 5; do
    rm -f "$partial"
    # bash<4.4 + set -u：空数组 "${arr[@]}" 会 unbound；用 + 扩展兜底
    if curl -fL --http1.1 --retry 3 --retry-delay 2 --connect-timeout 30 \
      -A "KOTV-prepare-runtime" \
      ${curl_auth[@]+"${curl_auth[@]}"} \
      -o "$partial" "$url" && [[ -s "$partial" ]]; then
      mv -f "$partial" "$dest"
      return
    fi
    echo "  retry $i ..."
    sleep $((i * 2))
  done
  rm -f "$partial"
  echo "ERROR: download failed: $url" >&2
  return 1
}

# --- JRE（全平台 BellSoft Liberica 21）---
# Windows amd64 另注入 api-ms-win-core-path，尽量兼容 Win7 SP1+（Liberica 文档含 Win7）。
prepare_jre() {
  local plat="$1" dest="$OUT_ROOT/jre"
  local jre_ver="$LIBERICA_FEATURE"

  jre_complete_for_plat() {
    case "$plat" in
      windows-*)
        # Liberica Windows：必须有 java.exe、jvm.dll、以及完整 jre/lib（modules 等）
        # 曾被 CMake PATTERN "lib" EXCLUDE 误删 lib/ → bridge EOF
        [[ -f "$dest/bin/java.exe" ]] \
          && [[ -d "$dest/lib" ]] \
          && [[ -f "$dest/lib/modules" || -f "$dest/lib/jrt-fs.jar" ]] \
          && { [[ -f "$dest/bin/server/jvm.dll" ]] || [[ -f "$dest/bin/client/jvm.dll" ]]; }
        ;;
      linux-*)
        [[ -x "$dest/bin/java" ]] && [[ -d "$dest/lib" ]] && [[ -f "$dest/lib/server/libjvm.so" || -f "$dest/lib/libjvm.so" ]]
        ;;
      macos-*)
        [[ -x "$dest/bin/java" || -x "$dest/Contents/Home/bin/java" ]] && {
          [[ -d "$dest/lib" ]] || [[ -d "$dest/Contents/Home/lib" ]]
        }
        ;;
      *) return 1 ;;
    esac
  }

  if jre_complete_for_plat; then
    echo "[jre] already present and complete: $dest"
    if [[ -x "$dest/Contents/Home/bin/java" && ! -x "$dest/bin/java" ]]; then
      echo "[jre] normalizing macOS layout"
      local tmp="$dest._home"
      mv "$dest/Contents/Home" "$tmp"
      rm -rf "$dest"
      mv "$tmp" "$dest"
    fi
    if [[ "$plat" == "windows-x64" ]]; then
      patch_jre_win7_crt "$dest"
    fi
    return
  fi

  if [[ -d "$dest" ]]; then
    echo "[jre] incomplete or wrong platform at $dest — re-downloading for $plat"
    rm -rf "$dest"
  fi

  local os arch pkg ext
  case "$plat" in
    windows-x64)   os=windows; arch=x86; pkg=zip;    ext=zip ;;
    windows-arm64) os=windows; arch=arm; pkg=zip;    ext=zip ;;
    linux-x64)     os=linux;   arch=x86; pkg=tar.gz; ext=tar.gz ;;
    linux-arm64)   os=linux;   arch=arm; pkg=tar.gz; ext=tar.gz ;;
    macos-x64)     os=macos;   arch=x86; pkg=tar.gz; ext=tar.gz ;;
    macos-arm64)   os=macos;   arch=arm; pkg=tar.gz; ext=tar.gz ;;
    *) echo "skip jre for $plat"; return ;;
  esac

  echo "[jre] resolving Liberica ${jre_ver} JRE ($plat) ..."
  local url
  url="$(
    curl -fsSL --http1.1 --connect-timeout 30 \
      -A "KOTV-prepare-runtime" \
      "https://api.bell-sw.com/v1/liberica/releases?version-feature=${jre_ver}&os=${os}&arch=${arch}&bitness=64&package-type=${pkg}&bundle-type=jre&version-modifier=latest" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d, "no Liberica releases"; print(d[0]["downloadUrl"])'
  )"
  [[ -n "$url" ]] || { echo "ERROR: Liberica download URL empty for $plat" >&2; exit 1; }
  local archive="$CACHE/jre-liberica-${plat}.${ext}"
  echo "[jre] downloading Liberica JRE: $url"
  download "$url" "$archive"

  rm -rf "$dest"
  mkdir -p "$dest"
  local tmp="$CACHE/jre-extract-$plat"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  if [[ "$ext" == "zip" ]]; then
    unzip -q "$archive" -d "$tmp"
  else
    tar -xzf "$archive" -C "$tmp"
  fi
  local home
  home="$(find "$tmp" -type f \( -path '*/bin/java' -o -path '*/bin/java.exe' \) | head -1 | xargs dirname | xargs dirname)"
  if [[ -z "$home" || ! -d "$home" ]]; then
    echo "ERROR: cannot locate JRE home in $archive" >&2
    exit 1
  fi
  if [[ -d "$home/Contents/Home" ]]; then
    home="$home/Contents/Home"
  fi
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  mv "$home" "$dest"
  rm -rf "$tmp"
  chmod -R a+rX "$dest" || true
  [[ -f "$dest/bin/java" ]] && chmod +x "$dest/bin/java"
  if [[ "$plat" == "windows-x64" ]]; then
    patch_jre_win7_crt "$dest"
  fi
  if ! jre_complete_for_plat; then
    echo "ERROR: [jre] after extract still incomplete for $plat under $dest" >&2
    echo "  expect bin/java(.exe) + lib/modules (or jrt-fs.jar) + jvm native lib" >&2
    ls -la "$dest" "$dest/bin" "$dest/lib" 2>&1 | head -40 >&2 || true
    exit 1
  fi
  echo "[jre] ready (Liberica ${jre_ver}): $dest"
  if [[ -f "$dest/bin/java.exe" ]]; then
    echo "[jre] windows java.exe present (bundled for JAR spiders)"
  fi
  local n
  n="$(find "$dest/lib" -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "[jre] lib/ file count: $n"
}

# 将 Win10 路径 API 垫片放入 jre/bin（缺 path API 时 Win7 无法启动）
# DLL 来源与 PythonVista 相同：https://github.com/adang1345/api-ms-win-core-path
patch_jre_win7_crt() {
  local jre_home="$1"
  local bin="$jre_home/bin"
  mkdir -p "$bin"
  local path_dll="api-ms-win-core-path-l1-1-0.dll"
  if [[ -f "$bin/$path_dll" ]]; then
    echo "[jre] Win7 CRT shim already present: $path_dll"
  else
    local zip="$CACHE/api-ms-win-core-path.zip"
    download "https://github.com/adang1345/api-ms-win-core-path/releases/download/v1.0.0/api-ms-win-core-path.zip" "$zip"
    local tmp="$CACHE/api-ms-win-core-path-extract"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    unzip -q "$zip" -d "$tmp"
    if [[ -f "$tmp/x64/$path_dll" ]]; then
      cp "$tmp/x64/$path_dll" "$bin/"
      echo "[jre] injected Win7 shim: $bin/$path_dll"
    else
      echo "WARNING: $path_dll not found in api-ms-win-core-path.zip" >&2
    fi
    rm -rf "$tmp"
  fi
 # 若 JRE 包缺 MSVC 运行库，从同平台 PythonVista 目录补一份（随包 CRT）
  local py_bin="$OUT_ROOT/python"
  local dll
  for dll in vcruntime140.dll vcruntime140_1.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll; do
    if [[ ! -f "$bin/$dll" && -f "$py_bin/$dll" ]]; then
      cp "$py_bin/$dll" "$bin/"
      echo "[jre] copied $dll from bundled PythonVista"
    fi
  done
  cat > "$jre_home/.kotv-win7" <<EOF
# Win7 SP1 尽力兼容
# - Liberica 21 JRE（BellSoft 文档含 Win7 SP1+）
# - api-ms-win-core-path-l1-1-0.dll：Win7 缺失的 Win10 路径 API 垫片
patched=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

# --- Python (python-build-standalone / Win7 embed) ---
# 依赖清单见 scripts/python-requirements.txt
patch_windows_python_pth() {
  local dest="$1"
  local pth
  pth="$(find "$dest" -maxdepth 1 -name 'python*._pth' | head -1 || true)"
  [[ -n "$pth" ]] || return 0
  # embed 默认忽略 site；必须写入 Lib\site-packages + import site
  grep -q 'Lib\\site-packages' "$pth" 2>/dev/null || echo 'Lib\site-packages' >> "$pth"
  if grep -q '^#import site' "$pth" 2>/dev/null; then
    # macOS/Linux sed；Windows Git Bash 也支持
    sed -i 's/^#import site/import site/' "$pth" 2>/dev/null \
      || sed -i.bak 's/^#import site/import site/' "$pth"
  fi
  grep -q '^import site$' "$pth" 2>/dev/null || echo "import site" >> "$pth"
  echo "[python] patched embed ._pth: $pth"
  cat "$pth" || true
}

install_python_packages() {
  local plat="$1" dest="$2"
  local python=""
  if [[ -f "$dest/python.exe" ]]; then
    python="$dest/python.exe"
  elif [[ -x "$dest/bin/python3" ]]; then
    python="$dest/bin/python3"
  elif [[ -x "$dest/bin/python" ]]; then
    python="$dest/bin/python"
  fi
  if [[ -z "$python" ]]; then
    echo "ERROR: bundled Python executable missing: $dest" >&2
    return 1
  fi

  local target=""
  case "$plat" in
    windows-*) target="$dest/Lib/site-packages" ;;
    macos-*|linux-*) target="$dest/lib/python${PYTHON_MM}/site-packages" ;;
    *) echo "ERROR: unsupported Python platform: $plat" >&2; return 1 ;;
  esac
  mkdir -p "$target"

  if [[ "$plat" == windows-* ]]; then
    patch_windows_python_pth "$dest"
  fi

  echo "[python] installing spider dependencies → $target ..."

  # Windows embed：始终 --target，避免 pip 装到用户目录或装不上
  # 跨平台（在 mac/linux 上为 windows 备包）：host pip + --platform
  local hostpy=""
  hostpy="$(command -v python3 || command -v python || true)"

  if [[ "$plat" == windows-* ]]; then
    local pip_platform="win_amd64"
    [[ "$plat" == "windows-arm64" ]] && pip_platform="win_arm64"
    if [[ -n "$hostpy" ]]; then
      "$hostpy" -m pip install --upgrade --target "$target" \
        --platform "$pip_platform" --implementation cp --python-version "$PYTHON_MM" --abi "$PYTHON_ABI" \
        --only-binary=:all: -r "$ROOT/scripts/python-requirements.txt"
    elif "$python" --version >/dev/null 2>&1; then
      if ! "$python" -m pip --version >/dev/null 2>&1; then
        "$python" -m ensurepip --upgrade >/dev/null 2>&1 || {
          local getpip="$CACHE/get-pip.py"
          download "https://bootstrap.pypa.io/get-pip.py" "$getpip"
          "$python" "$getpip" --no-warn-script-location
        }
      fi
      "$python" -m pip install --upgrade --target "$target" --no-warn-script-location \
        -r "$ROOT/scripts/python-requirements.txt"
    else
      echo "ERROR: cannot install Windows Python wheels (need host python3 or runnable python.exe)" >&2
      return 1
    fi
  else
    if ! "$python" --version >/dev/null 2>&1; then
      [[ -n "$hostpy" ]] || { echo "ERROR: host Python required for cross-platform wheels" >&2; return 1; }
      local pip_platform
      case "$plat" in
        macos-x64) pip_platform="macosx_10_13_x86_64" ;;
        macos-arm64) pip_platform="macosx_11_0_arm64" ;;
        linux-x64) pip_platform="manylinux2014_x86_64" ;;
        linux-arm64) pip_platform="manylinux2014_aarch64" ;;
      esac
      "$hostpy" -m pip install --upgrade --target "$target" \
        --platform "$pip_platform" --implementation cp --python-version "$PYTHON_MM" --abi "$PYTHON_ABI" \
        --only-binary=:all: -r "$ROOT/scripts/python-requirements.txt"
    else
      if ! "$python" -m pip --version >/dev/null 2>&1; then
        "$python" -m ensurepip --upgrade >/dev/null 2>&1 || {
          local getpip="$CACHE/get-pip.py"
          download "https://bootstrap.pypa.io/get-pip.py" "$getpip"
          "$python" "$getpip" --no-warn-script-location
        }
      fi
      "$python" -m pip install --upgrade --no-warn-script-location \
        -r "$ROOT/scripts/python-requirements.txt"
    fi
  fi

  [[ -d "$target/requests" && -d "$target/lxml" && -d "$target/Crypto" && -d "$target/urllib3" ]] || {
    echo "ERROR: Python dependencies incomplete under $target" >&2
    echo "  need: requests lxml Crypto urllib3 (same as TV/chaquo)" >&2
    ls -la "$target" 2>&1 | head -40 >&2 || true
    return 1
  }
  echo "[python] dependencies verified at $target"
}

prepare_python() {
  local plat="$1" dest="$OUT_ROOT/python"
  if [[ -x "$dest/bin/python3" || -f "$dest/python.exe" ]]; then
    echo "[python] already present: $dest"
    install_python_packages "$plat" "$dest"
    return
  fi
  local url name kind
  case "$plat" in
    macos-arm64)
      name="cpython-${PYTHON_VER}+${PYTHON_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
      url="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_TAG}/$name"
      kind=pbs
      ;;
    macos-x64)
      name="cpython-${PYTHON_VER}+${PYTHON_TAG}-x86_64-apple-darwin-install_only_stripped.tar.gz"
      url="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_TAG}/$name"
      kind=pbs
      ;;
    linux-x64)
      name="cpython-${PYTHON_VER}+${PYTHON_TAG}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
      url="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_TAG}/$name"
      kind=pbs
      ;;
    linux-arm64)
      name="cpython-${PYTHON_VER}+${PYTHON_TAG}-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz"
      url="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_TAG}/$name"
      kind=pbs
      ;;
    windows-x64)
      name="python-${PYTHON_VER}-embed-amd64.zip"
      # 资产在 Releases，不在 raw master 路径
      url="https://github.com/adang1345/PythonVista/releases/download/v${PYTHON_VER}/$name"
      kind=win
      ;;
    windows-arm64)
      name="cpython-${PYTHON_VER}+${PYTHON_TAG}-aarch64-pc-windows-msvc-install_only_stripped.tar.gz"
      url="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_TAG}/$name"
      kind=pbs
      ;;
 *) echo "skip python for $plat"; return ;;
  esac
  local archive="$CACHE/$name"
  download "$url" "$archive"
  rm -rf "$dest"
  mkdir -p "$dest"
  if [[ "$kind" == "win" ]]; then
    unzip -q "$archive" -d "$dest"
    patch_windows_python_pth "$dest"
  else
    local tmp="$CACHE/py-extract-$plat"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    tar -xzf "$archive" -C "$tmp"
 # PBS install_only 解压后为 python/ 目录
    if [[ -d "$tmp/python" ]]; then
      mv "$tmp/python"/* "$dest"/
    else
 # 或单层
      local top
      top="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
      mv "$top"/* "$dest"/
    fi
    rm -rf "$tmp"
    chmod +x "$dest/bin/python3" 2>/dev/null || true
  fi
  echo "[python] ready: $dest"
  install_python_packages "$plat" "$dest"
}

# --- Chromium ---
# Windows x64（Win7）：解包 Chromium-for-windows-7-REWORK 最新 Release 的 mini_installer_x64.exe
#   → chrome.7z → Chrome-bin 内容直接放入 runtime/chromium/（版本不写死，跟仓库最新）。
# Windows ARM64 仅 Win11：优先 CFT 最新 chrome-headless-shell；CFT 暂无 win-arm64 时
# 回退 Chromium snapshot Win_Arm64/LAST_CHANGE（官方 zip 内 chrome-win/ 会展平到 chromium/）。
# 其它平台用 chrome-for-testing 最新 headless-shell。
CHROMIUM_WIN7_REWORK_REPO="e3kskoy7wqk/Chromium-for-windows-7-REWORK"
CHROMIUM_SNAPSHOT_BASE="https://storage.googleapis.com/chromium-browser-snapshots"
# mjd7989：Win7 DirectWrite + 彩色 emoji（seguiemj.ttf）；随 REWORK Release 说明分发
CHROMIUM_WIN7_DWRITE_URL="${CHROMIUM_WIN7_DWRITE_URL:-https://github.com/user-attachments/files/28444470/webgl_hw_and_dwrite.zip}"
CHROMIUM_WIN7_DWRITE_STAMP="dwrite-w7-x64-seguiemj-v1"

_find_7z() {
  if command -v 7z >/dev/null 2>&1; then
    command -v 7z
    return 0
  fi
  if command -v 7zz >/dev/null 2>&1; then
    command -v 7zz
    return 0
  fi
  return 1
}

# 解析 REWORK 最新带 mini_installer_x64.exe 的 Release：打印 "tag\turl"
# 使用 GITHUB_TOKEN/GH_TOKEN（CI 必填）避免匿名 API 403 rate limit。
_win7_rework_latest_installer() {
  python3 - "$CHROMIUM_WIN7_REWORK_REPO" <<'PY'
import json, os, sys, time, urllib.error, urllib.request

repo = sys.argv[1]
# (sandbox fallback) KOTV_CHROMIUM_WIN7_TAG overrides the GitHub API lookup
env_tag = (os.environ.get("KOTV_CHROMIUM_WIN7_TAG") or "").strip()
if env_tag:
    print(env_tag + "\t" + f"https://github.com/{repo}/releases/download/{env_tag}/mini_installer_x64.exe")
    raise SystemExit(0)
url = f"https://api.github.com/repos/{repo}/releases?per_page=20"
token = (os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or "").strip()
headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "KOTV-prepare-runtime",
    "X-GitHub-Api-Version": "2022-11-28",
}
if token:
    headers["Authorization"] = f"Bearer {token}"
else:
    print(
        "WARN: GITHUB_TOKEN/GH_TOKEN unset; GitHub API may 403 (rate limit)",
        file=sys.stderr,
    )

releases = None
last_err = None
for attempt in range(1, 6):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            releases = json.load(resp)
        break
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")[:300]
        except Exception:
            pass
        last_err = f"HTTP {e.code} {e.reason}: {body}"
        # 403/429：等一等再试（带 token 后通常不会踩匿名配额）
        if e.code in (403, 429) and attempt < 5:
            time.sleep(attempt * 3)
            continue
        print(f"ERROR: GitHub releases API failed: {last_err}", file=sys.stderr)
        raise SystemExit(1)
    except Exception as e:
        last_err = str(e)
        if attempt < 5:
            time.sleep(attempt * 2)
            continue
        print(f"ERROR: GitHub releases API failed: {last_err}", file=sys.stderr)
        raise SystemExit(1)

if not isinstance(releases, list):
    print(f"ERROR: unexpected releases payload: {type(releases)}", file=sys.stderr)
    raise SystemExit(1)

for rel in releases:
    if rel.get("draft") or rel.get("prerelease"):
        continue
    tag = (rel.get("tag_name") or "").strip()
    if not tag:
        continue
    for asset in rel.get("assets") or []:
        name = (asset.get("name") or "").lower()
        dl = asset.get("browser_download_url") or ""
        if name == "mini_installer_x64.exe" and dl:
            print(tag + "\t" + dl)
            raise SystemExit(0)
print(f"ERROR: no mini_installer_x64.exe in first {len(releases)} releases of {repo}", file=sys.stderr)
raise SystemExit(1)
PY
}

# 解压官方 chrome-win.zip：将 chrome-win/（或顶层目录）内容展平到 dest，不保留 chrome-win 子目录。
_extract_chrome_win_zip() {
  local archive="$1" dest="$2" plat="$3" label="$4"
  local tmp="$CACHE/chrome-extract-$plat" src
  rm -rf "$tmp" "$dest"
  mkdir -p "$tmp" "$dest"
  unzip -q "$archive" -d "$tmp"
  if [[ -d "$tmp/chrome-win" ]]; then
    src="$tmp/chrome-win"
  else
    src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  fi
  if [[ -z "$src" || ! -d "$src" ]]; then
    echo "ERROR: chrome-win layout not found in $archive" >&2
    return 1
  fi
  cp -a "$src"/. "$dest/"
  rm -rf "$tmp"
  if [[ ! -f "$dest/chrome.exe" ]]; then
    echo "ERROR: chrome.exe missing after extract to $dest" >&2
    return 1
  fi
  echo "[chromium] ready ($label): $dest"
}

# 解包 Win7 REWORK mini_installer_x64.exe → Chrome-bin 内容直接放入 dest
# 参数: installer dest stamp label
_extract_win7_rework_mini_installer() {
  local installer="$1" dest="$2" stamp="$3" label="$4"
  local seven tmp chrome7z packed bin
  if ! seven="$(_find_7z)"; then
    echo "ERROR: need 7z to unpack Chromium mini_installer" >&2
    return 1
  fi
  tmp="$CACHE/chrome-win7-rework-extract"
  rm -rf "$tmp" "$dest"
  mkdir -p "$tmp/s1" "$tmp/s2" "$dest"

  # PE 资源里嵌套 CHROME.PACKED.7Z；7z 对整包 x 时常直接抽出内层 chrome.7z
  echo "[chromium] unpack mini_installer → chrome.7z"
  "$seven" x -y "-o$tmp/s1" "$installer" >/dev/null
  chrome7z="$(find "$tmp/s1" -iname 'chrome.7z' | head -1 || true)"
  if [[ -z "$chrome7z" ]]; then
    packed="$(find "$tmp/s1" \( -iname 'CHROME.PACKED.7Z' -o -iname 'chrome.packed.7z' \) | head -1 || true)"
    if [[ -z "$packed" ]]; then
      echo "ERROR: chrome.7z / CHROME.PACKED.7Z not found in mini_installer" >&2
      find "$tmp/s1" -maxdepth 3 -type f | head -40 >&2 || true
      return 1
    fi
    echo "[chromium] unpack CHROME.PACKED.7Z → chrome.7z"
    mkdir -p "$tmp/s1b"
    "$seven" x -y "-o$tmp/s1b" "$packed" >/dev/null
    chrome7z="$(find "$tmp/s1" "$tmp/s1b" -iname 'chrome.7z' | head -1 || true)"
  fi
  if [[ -z "$chrome7z" || ! -f "$chrome7z" ]]; then
    echo "ERROR: chrome.7z missing after mini_installer unpack" >&2
    return 1
  fi

  echo "[chromium] unpack chrome.7z → Chrome-bin"
  "$seven" x -y "-o$tmp/s2" "$chrome7z" >/dev/null
  if [[ -d "$tmp/s2/Chrome-bin" ]]; then
    bin="$tmp/s2/Chrome-bin"
  else
    bin="$(dirname "$(find "$tmp/s2" -name 'chrome.exe' | head -1)")"
  fi
  if [[ -z "$bin" || ! -f "$bin/chrome.exe" ]]; then
    echo "ERROR: Chrome-bin/chrome.exe not found after chrome.7z extract" >&2
    find "$tmp/s2" -maxdepth 3 | head -40 >&2 || true
    return 1
  fi

  cp -a "$bin"/. "$dest/"
  printf '%s\n' "$stamp" >"$dest/.kotv-chromium"
  rm -rf "$tmp"
  echo "[chromium] ready ($label): $dest"
}

# Win7 REWORK：把 dwrite_w7_x64 + Segoe UI Emoji 放到 chrome.exe 旁（彩色 emoji / 更好的字体渲染）
# 说明见 zip 内 readme：Win7 RTM+ 用 dwrite_w7_x64；还需安装 seguiemj.ttf（一并放入 chromium/ 供安装包注册）。
_ensure_win7_chromium_dwrite() {
  local dest="$1"
  [[ -f "$dest/chrome.exe" ]] || return 0
  if [[ -f "$dest/.kotv-chromium-dwrite" && "$(cat "$dest/.kotv-chromium-dwrite" 2>/dev/null || true)" == "$CHROMIUM_WIN7_DWRITE_STAMP" ]] \
    && [[ -f "$dest/DWrite.dll" ]] && [[ -f "$dest/seguiemj.ttf" ]]; then
    echo "[chromium] Win7 DWrite/emoji already applied ($CHROMIUM_WIN7_DWRITE_STAMP)"
    return 0
  fi
  local zip="$CACHE/webgl_hw_and_dwrite.zip"
  local tmp="$CACHE/webgl_hw_and_dwrite-extract"
  echo "[chromium] apply Win7 DWrite + Segoe UI Emoji (color emoji)"
  download "$CHROMIUM_WIN7_DWRITE_URL" "$zip" || {
    echo "WARNING: download DWrite pack failed; skip color-emoji patch" >&2
    return 0
  }
  rm -rf "$tmp"
  mkdir -p "$tmp"
  if ! unzip -q -o "$zip" -d "$tmp"; then
    echo "WARNING: unzip DWrite pack failed; skip" >&2
    return 0
  fi
  local src="$tmp/dwrite_w7_x64"
  if [[ ! -d "$src" ]]; then
    echo "WARNING: dwrite_w7_x64 missing in pack; skip" >&2
    return 0
  fi
  # 覆盖到 chrome.exe 同目录（勿覆盖系统盘；仅捆绑 runtime）
  cp -f "$src/"*.dll "$dest/" 2>/dev/null || true
  if [[ -f "$tmp/seguiemj.ttf" ]]; then
    cp -f "$tmp/seguiemj.ttf" "$dest/seguiemj.ttf"
  fi
  if [[ -f "$tmp/readme.txt" ]]; then
    cp -f "$tmp/readme.txt" "$dest/README-dwrite-emoji.txt"
  fi
  printf '%s\n' "$CHROMIUM_WIN7_DWRITE_STAMP" >"$dest/.kotv-chromium-dwrite"
  echo "[chromium] DWrite/emoji applied → $dest (DWrite.dll + seguiemj.ttf)"
  rm -rf "$tmp"
}

# 尝试 CFT Stable：优先 chrome-headless-shell，其次 chrome。成功打印 kind\turl 到 stdout。
_cft_stable_url() {
  local meta="$1" cft_plat="$2"
  python3 - "$meta" "$cft_plat" <<'PY' || true
import json,sys
meta=json.load(open(sys.argv[1]))
plat=sys.argv[2]
dls_root=meta["channels"]["Stable"]["downloads"]
for kind in ("chrome-headless-shell","chrome"):
    for d in dls_root.get(kind,[]):
        if d.get("platform")==plat and d.get("url"):
            print(kind + "\t" + d["url"])
            raise SystemExit(0)
raise SystemExit(1)
PY
}

_install_cft_zip() {
  local plat="$1" kind="$2" url="$3" dest="$4"
  echo "[chromium] using CFT $kind"
  local archive="$CACHE/chromium-${kind}-${plat}.zip"
  download "$url" "$archive"
  local tmp="$CACHE/chrome-extract-$plat"
  rm -rf "$tmp" "$dest"
  mkdir -p "$tmp" "$dest"
  unzip -q "$archive" -d "$tmp"
  local inner
  inner="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  if [[ -n "$inner" ]]; then
    mv "$inner"/* "$dest"/
  else
    mv "$tmp"/* "$dest"/
  fi
  rm -rf "$tmp"
  chmod +x "$dest/chrome-headless-shell" 2>/dev/null || true
  find "$dest" -type f \( -name 'chrome-headless-shell' -o -name 'chrome' -o -name 'chrome.exe' \) -exec chmod +x {} \;
  echo "[chromium] ready ($kind): $dest"
}

prepare_chromium() {
  local plat="$1" dest="$OUT_ROOT/chromium"

  if [[ "$plat" == "windows-x64" ]]; then
    local info tag url stamp installer
    echo "[chromium] resolve latest Win7 REWORK mini_installer_x64.exe"
    if ! info="$(_win7_rework_latest_installer)"; then
      echo "ERROR: resolve mini_installer_x64.exe from ${CHROMIUM_WIN7_REWORK_REPO} failed" >&2
      return 1
    fi
    if [[ -z "${info:-}" ]]; then
      echo "ERROR: empty resolve result for ${CHROMIUM_WIN7_REWORK_REPO}" >&2
      return 1
    fi
    tag="${info%%$'\t'*}"
    url="${info#*$'\t'}"
    stamp="win7-rework-${tag}"
    if [[ -f "$dest/.kotv-chromium" && "$(cat "$dest/.kotv-chromium" 2>/dev/null || true)" == "$stamp" ]] \
      && [[ -f "$dest/chrome.exe" ]]; then
      echo "[chromium] already present ($stamp): $dest"
      _ensure_win7_chromium_dwrite "$dest"
      return
    fi
    installer="$CACHE/chromium-win7-rework-${tag}-mini_installer_x64.exe"
    echo "[chromium] Win7 REWORK Chromium ${tag} (unpack mini_installer_x64.exe)"
    download "$url" "$installer"
    _extract_win7_rework_mini_installer "$installer" "$dest" "$stamp" "Win7 REWORK ${tag}"
    _ensure_win7_chromium_dwrite "$dest"
    return
  fi

  if [[ -x "$dest/chrome-headless-shell" || -f "$dest/chrome-headless-shell.exe" || -f "$dest/chrome.exe" || -x "$dest/chrome" ]]; then
    echo "[chromium] already present: $dest"
    return
  fi

  # Windows ARM64（Win11+）：最新构建，官方源
  if [[ "$plat" == "windows-arm64" ]]; then
    local meta="$CACHE/chrome-for-testing.json"
    download "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json" "$meta" || true
    local cft_info kind url
    if [[ -f "$meta" ]]; then
      cft_info="$(_cft_stable_url "$meta" "win-arm64")"
    fi
    if [[ -n "${cft_info:-}" ]]; then
      kind="${cft_info%%$'\t'*}"
      url="${cft_info#*$'\t'}"
      _install_cft_zip "$plat" "$kind" "$url" "$dest"
      return
    fi
    echo "[chromium] CFT 尚无 win-arm64 → 使用最新 Chromium snapshot Win_Arm64"
    local rev archive
    rev="$(curl -fsSL --http1.1 --connect-timeout 30 "${CHROMIUM_SNAPSHOT_BASE}/Win_Arm64/LAST_CHANGE")"
    rev="$(echo "$rev" | tr -d '[:space:]')"
    if [[ -z "$rev" ]]; then
      echo "ERROR: cannot read Win_Arm64/LAST_CHANGE" >&2
      return 1
    fi
    echo "[chromium] Win_Arm64 latest rev $rev"
    url="${CHROMIUM_SNAPSHOT_BASE}/Win_Arm64/${rev}/chrome-win.zip"
    archive="$CACHE/chromium-win-arm64-${rev}.zip"
    download "$url" "$archive"
    _extract_chrome_win_zip "$archive" "$dest" "$plat" "Win_Arm64/latest rev $rev"
    return
  fi

  local cft_plat
  case "$plat" in
    macos-arm64) cft_plat="mac-arm64" ;;
    macos-x64)   cft_plat="mac-x64" ;;
    linux-x64)   cft_plat="linux64" ;;
    linux-arm64) echo "[chromium] linux-arm64: use system chrome or set manually"; return ;;
    *) return ;;
  esac
  local meta="$CACHE/chrome-for-testing.json"
  download "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json" "$meta"
  local cft_info kind url
  cft_info="$(_cft_stable_url "$meta" "$cft_plat")"
  if [[ -z "${cft_info:-}" ]]; then
    echo "[chromium] skip: Chrome for Testing 无 $cft_plat 构建（嗅探将回落系统 Chrome）"
    return 0
  fi
  kind="${cft_info%%$'\t'*}"
  url="${cft_info#*$'\t'}"
  _install_cft_zip "$plat" "$kind" "$url" "$dest"
}

# --- ffmpeg ---
prepare_ffmpeg() {
  local plat="$1" dest="$OUT_ROOT/ffmpeg"
  if [[ -x "$dest/ffmpeg" || -f "$dest/ffmpeg.exe" ]]; then
    echo "[ffmpeg] already present: $dest"
    return
  fi
  local url name
  case "$plat" in
    macos-arm64)
      url="https://www.osxexperts.net/ffmpeg71arm.zip"; name="ffmpeg71arm.zip" ;;
    macos-x64)
      url="https://github.com/ffbinaries/ffbinaries-prebuilt/releases/download/v6.1/ffmpeg-6.1-macos-64.zip"
      name="ffmpeg-6.1-macos-64.zip" ;;
    windows-x64)
      url="https://github.com/GyanD/codexffmpeg/releases/download/7.0/ffmpeg-7.0-full_build.zip"
      name="ffmpeg-7.0-full_build.zip" ;;
    windows-arm64)
      url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-winarm64-gpl.zip"
      name="ffmpeg-winarm64.zip" ;;
    linux-x64)
      url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
      name="ffmpeg-linux64.tar.xz" ;;
    linux-arm64)
      url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
      name="ffmpeg-linuxarm64.tar.xz" ;;
 *) return ;;
  esac
  local archive="$CACHE/$name"
  download "$url" "$archive"
  rm -rf "$dest"
  mkdir -p "$dest"
  local tmp="$CACHE/ff-extract-$plat"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  case "$archive" in
 *.zip) unzip -q "$archive" -d "$tmp" ;;
 *.tar.xz) tar -xJf "$archive" -C "$tmp" ;;
 *) tar -xzf "$archive" -C "$tmp" ;;
  esac
  local bin
  bin="$(find "$tmp" -type f \( -name ffmpeg -o -name ffmpeg.exe \) | head -1)"
  if [[ -z "$bin" ]]; then
    echo "ERROR: ffmpeg binary not found in $archive" >&2
    exit 1
  fi
  cp "$bin" "$dest/"
  chmod +x "$dest/ffmpeg" 2>/dev/null || true
  rm -rf "$tmp"
  echo "[ffmpeg] ready: $dest"
}

# --- libmpv ---
# 桌面页内 MPV 由 Flutter media_kit 自带；Go 引擎不做页内播放，runtime 不打包 libmpv。

prepare_one() {
  local plat="$1"
  echo "======== prepare runtime: $plat ========"
  mkdir -p "$CACHE" "$OUT_ROOT"
  # 不捆绑外部播放器目录（页内 MPV=media_kit；外部播放器用系统安装）
  rm -rf "$OUT_ROOT/mpv" "$OUT_ROOT/lib" "$OUT_ROOT/vlc" "$OUT_ROOT/libvlc" "$OUT_ROOT/libmpv"
  prepare_jre "$plat"
  prepare_python "$plat"
 # PythonVista 解压后可能带 vcruntime；再扫一遍补进 jre/bin
  if [[ "$plat" == "windows-x64" && -d "$OUT_ROOT/jre" ]]; then
    patch_jre_win7_crt "$OUT_ROOT/jre"
  fi
  prepare_chromium "$plat"
  prepare_ffmpeg "$plat"
  # bridge jar（体积变大也无所谓；缺依赖会导致爬虫全挂）
  if [[ ! -f "$ROOT/bridge/spider-bridge.jar" ]] || [[ "$ROOT/bridge/build.sh" -nt "$ROOT/bridge/spider-bridge.jar" ]] || [[ "$ROOT/bridge/build.gradle" -nt "$ROOT/bridge/spider-bridge.jar" ]] || [[ "$ROOT/bridge/settings.gradle" -nt "$ROOT/bridge/spider-bridge.jar" ]] || [[ "$ROOT/bridge/src/main/java/com/bobo/kotv/bridge/SpiderBridge.java" -nt "$ROOT/bridge/spider-bridge.jar" ]] || [[ "$ROOT/bridge/src/main/java/com/github/catvod/utils/UiBridge.java" -nt "$ROOT/bridge/spider-bridge.jar" ]] || [[ "$ROOT/bridge/src/main/java/com/github/catvod/crawler/Spider.java" -nt "$ROOT/bridge/spider-bridge.jar" ]]; then
    echo "[bridge] building fat jar..."
    (cd "$ROOT" && ./bridge/build.sh)
  fi
  mkdir -p "$OUT_ROOT/bridge"
  if [[ ! -f "$ROOT/bridge/spider-bridge.jar" ]]; then
    echo "ERROR: bridge/spider-bridge.jar missing after build" >&2
    return 1
  fi
  cp "$ROOT/bridge/spider-bridge.jar" "$OUT_ROOT/bridge/"
  cat > "$OUT_ROOT/.kotv-runtime" <<EOF
platform=$plat
prepared=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  echo "======== verifying $OUT_ROOT ========"
  "$ROOT/scripts/verify-runtime.sh" "$OUT_ROOT" "$plat"
  echo "======== done: $OUT_ROOT ========"
  echo "包含: jre / python / chromium / ffmpeg / bridge"
  echo "页内 MPV：Flutter media_kit 自带 libmpv（不进 runtime/）"
  echo "JS(QuickJS) 已编译进主程序 (CGO)。Windows 请用 MSVCRT MinGW 打包（见 package.sh / check-win7-deps.ps1）。"
}

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  TARGET="$(detect_platform)"
fi

case "$TARGET" in
  all)
    echo "ERROR: runtime/ 为单平台扁平布局，不支持 all；请按目标平台分别执行 prepare-runtime.sh <platform>" >&2
    exit 1
    ;;
 *)
    prepare_one "$TARGET"
    ;;
esac

echo
echo "运行时目录: $OUT_ROOT"
echo "打包时请将 runtime/ 与 KOTV 二进制放在同级 dist/ 中。"

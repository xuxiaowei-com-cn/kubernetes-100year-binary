#!/usr/bin/env bash
#
# download-releases.sh —— 下载本项目所有 Release 产物（kubeadm 二进制）
#
# 目录结构：
#   <输出目录>/<版本>/<架构>/kubeadm      例如：./v1.24.0/amd64/kubeadm
#
# 特性：
#   * 自动遍历 GitHub Release（分页），按资产名 kubeadm-<arch> 归档到 <版本>/<架构>/
#   * 已存在的文件用 Release 资产的 sha256（GitHub API 的 digest 字段）校验：
#       - HASH 一致 → 跳过（打印 SKIP 已校验）
#       - HASH 不一致 → 重新下载（打印 REDO）
#       - 大小不一致 → 直接重新下载（避免对大文件做无谓的哈希）
#   * 下载到 .part 临时文件，校验通过后才 mv 到位，避免半截文件
#   * 下载完成后为每个版本生成 SHA256SUMS（可离线 `cd v1.24.0 && sha256sum -c SHA256SUMS`）
#   * --verify-only 只校验不下载；GitHub API 不可用时自动回退到本地 SHA256SUMS 校验
#   * 可选 --check-tags：列出还没有 Release 的标签（CI 还没跑完时会看到）
#   * 支持下载代理：--proxy 给资产下载地址加前缀（GitHub 直连慢时用）
#       加前缀后：https://gh-proxy.org/https://github.com/.../kubeadm-amd64
#
# 依赖：bash、curl、sha256sum 或 shasum、python3（仅用于解析 JSON）
#
# 用法示例：
#   ./download-releases.sh                          # 下载全部到当前目录
#   ./download-releases.sh -d /data/kubeadm         # 指定输出目录
#   ./download-releases.sh -j 8                     # 8 个并发下载
#   ./download-releases.sh --version-regex '^v1\.31\.'   # 只下载 1.31.x
#   ./download-releases.sh --arch arm64             # 只下载 arm64
#   ./download-releases.sh --verify-only            # 只校验已有文件
#   ./download-releases.sh --force                  # 忽略已有文件全部重下
#   ./download-releases.sh --proxy https://gh-proxy.org/           # 走代理下载
#   DOWNLOAD_PROXY=https://gh-proxy.org/ ./download-releases.sh     # 同上（环境变量）
#   ./download-releases.sh --log download.log      # 同时把日志写入文件（带时间戳）
#   GITHUB_TOKEN=xxx ./download-releases.sh         # 提高 API 速率上限
#
# 说明：--proxy 只作用于 Release 资产下载；如果 API 也需要走代理，
#       可用 GITHUB_API=https://gh-proxy.org/https://api.github.com 指定。
#
set -uo pipefail

PROG=$(basename "$0")
REPO="${REPO:-xuxiaowei-com-cn/kubernetes-100year-binary}"
API="${GITHUB_API:-https://api.github.com}"
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
PROXY="${DOWNLOAD_PROXY:-${GH_PROXY:-}}"

OUT_DIR="."
JOBS=4
FORCE=0
VERIFY_ONLY=0
LIST_ONLY=0
CHECK_TAGS=1
VERSION_REGEX=""
ARCH_FILTER=""
LOG_FILE="${LOG_FILE:-}"

# ---------------------------------------------------------------------------
# 输出与工具函数
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_OFF=""
fi

info()  { printf '%s\n' "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
error() { printf '%s[error]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()   { error "$*"; exit 2; }

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit 0
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "需要 sha256sum 或 shasum 来计算校验和"
  fi
}

file_size() {
  if stat -f %z "$1" >/dev/null 2>&1; then stat -f %z "$1"; else stat -c %s "$1"; fi
}

api_get() { # api_get <url> <输出文件>
  local url="$1" out="$2"
  local args=(-fsSL --retry 3 --retry-delay 2 --connect-timeout 15
              -H 'Accept: application/vnd.github+json'
              -H 'X-GitHub-Api-Version: 2022-11-28')
  [ -n "$TOKEN" ] && args+=(-H "Authorization: Bearer $TOKEN")
  curl "${args[@]}" -o "$out" "$url"
}

json_len() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$1"; }

# 给资产下载地址加代理前缀：https://gh-proxy.org/ + https://github.com/...
proxy_url() {
  if [ -n "$PROXY" ]; then printf '%s%s' "$PROXY" "$1"; else printf '%s' "$1"; fi
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--dir)          OUT_DIR="${2:?--dir 需要参数}"; shift 2 ;;
    -j|--jobs)         JOBS="${2:?--jobs 需要参数}"; shift 2 ;;
    -r|--repo)         REPO="${2:?--repo 需要参数}"; shift 2 ;;
    -p|--proxy)        PROXY="${2:?--proxy 需要参数}"; shift 2 ;;
    --log)             LOG_FILE="${2:?--log 需要参数}"; shift 2 ;;
    --version-regex)   VERSION_REGEX="${2:?--version-regex 需要参数}"; shift 2 ;;
    --arch)            ARCH_FILTER="${2:?--arch 需要参数}"; shift 2 ;;
    --force)           FORCE=1; shift ;;
    --verify-only)     VERIFY_ONLY=1; shift ;;
    --list|--dry-run)  LIST_ONLY=1; shift ;;
    --no-check-tags)   CHECK_TAGS=0; shift ;;
    -h|--help)         usage ;;
    *)                 die "未知参数：$1（--help 查看用法）" ;;
  esac
done

case "$JOBS" in ''|*[!0-9]*) die "--jobs 需要正整数" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs 需要正整数"
command -v curl >/dev/null 2>&1 || die "需要 curl"
command -v python3 >/dev/null 2>&1 || die "需要 python3（用于解析 GitHub API 的 JSON）"

# 代理前缀统一补上结尾的 /
if [ -n "$PROXY" ]; then
  case "$PROXY" in
    */) ;;
    *) PROXY="$PROXY/" ;;
  esac
fi

mkdir -p "$OUT_DIR" || die "无法创建输出目录：$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)

if [ "$OUT_DIR" = "$(pwd)" ] && git rev-parse --git-dir >/dev/null 2>&1; then
  warn "当前目录是 git 仓库，产物会成为未跟踪文件；建议用 -d DIR 指定输出目录"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/download-releases.XXXXXX") || die "无法创建临时目录"
RESULTS="$TMP/results.tsv"
: > "$RESULTS"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

info "${C_BLUE}==>${C_OFF} 仓库：$REPO"
info "${C_BLUE}==>${C_OFF} 输出目录：$OUT_DIR"
[ -n "$PROXY" ] && info "${C_BLUE}==>${C_OFF} 下载代理：$PROXY"
[ "$VERIFY_ONLY" = 1 ] && info "${C_BLUE}==>${C_OFF} 模式：只校验，不下载"
[ "$LIST_ONLY" = 1 ] && info "${C_BLUE}==>${C_OFF} 模式：只列出，不下载"

# ---------------------------------------------------------------------------
# 单个资产的校验 / 下载（并行执行，结果追加到 $RESULTS）
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 日志与结果记录
# ---------------------------------------------------------------------------
ts() { date '+%H:%M:%S'; }

log_block() { # log_block "<文本块>"：整块一次性输出，避免并行下载时多行日志互相穿插
  printf '%s\n' "$1"
  if [ -n "$LOG_FILE" ]; then
    printf '%s\n' "$1" | sed $'s/\033\\[[0-9;]*m//g' | while IFS= read -r line; do
      printf '%s %s\n' "$(date '+%F %T')" "$line"
    done >> "$LOG_FILE"
  fi
}

record() { # record <状态> <版本> <架构> <说明>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"
}

do_one() { # do_one <版本> <架构> <url> <sha256> <size>
  local ver="$1" arch="$2" url="$3" sha="$4" size="$5"
  local dir dest part
  dir="$OUT_DIR/$ver/$arch"
  dest="$dir/kubeadm"
  part="$dir/.kubeadm.part"

  if [ "$LIST_ONLY" = 1 ]; then
    log_block "$(printf '[%s] %s/%s\n           来源: %s\n           目标: %s\n           大小: %s 字节\n           sha256: %s' \
      "$(ts)" "$ver" "$arch" "$url" "$dest" "$size" "${sha:--}")"
    return 0
  fi

  if ! mkdir -p "$dir"; then
    record FAIL "$ver" "$arch" "创建目录失败：$dir"
    log_block "$(printf '[%s] %s[FAIL]%s %s/%s 创建目录失败: %s' "$(ts)" "$C_RED" "$C_OFF" "$ver" "$arch" "$dir")"
    return 1
  fi

  # ---- 已存在：先比大小，再比 HASH ----
  if [ -f "$dest" ] && [ "$FORCE" = 0 ]; then
    local local_size local_hash redo_reason=""
    local_size=$(file_size "$dest")
    if [ -n "$size" ] && [ "$size" != "0" ] && [ "$local_size" != "$size" ]; then
      redo_reason="大小不一致（本地 $local_size ≠ 远端 $size）"
    else
      local_hash=$(sha256_of "$dest")
      if [ -z "$sha" ] || [ "$local_hash" = "$sha" ]; then
        record SKIP "$ver" "$arch" "已存在且 HASH 一致（${local_hash:0:12}）"
        log_block "$(printf '[%s] %s[SKIP]%s %s/%s 已存在，HASH 校验通过\n           文件: %s\n           大小: %s 字节\n           sha256: %s' \
          "$(ts)" "$C_GREEN" "$C_OFF" "$ver" "$arch" "$dest" "$local_size" "$local_hash")"
        return 0
      fi
      redo_reason="HASH 不一致（本地 ${local_hash:0:12}… ≠ 远端 ${sha:0:12}…）"
    fi
    # 只校验模式：不下探到“重新下载”，直接报错
    if [ "$VERIFY_ONLY" = 1 ]; then
      record FAIL "$ver" "$arch" "$redo_reason"
      log_block "$(printf '[%s] %s[FAIL]%s %s/%s 与 Release 不一致\n           文件: %s\n           原因: %s\n           期望 sha256: %s' \
        "$(ts)" "$C_RED" "$C_OFF" "$ver" "$arch" "$dest" "$redo_reason" "${sha:--}")"
      return 1
    fi
    record REDO "$ver" "$arch" "$redo_reason"
    log_block "$(printf '[%s] %s[REDO]%s %s/%s %s，重新下载\n           文件: %s' \
      "$(ts)" "$C_YELLOW" "$C_OFF" "$ver" "$arch" "$redo_reason" "$dest")"
  fi

  # ---- 只校验模式 ----
  if [ "$VERIFY_ONLY" = 1 ]; then
    if [ ! -f "$dest" ]; then
      record MISSING "$ver" "$arch" "文件不存在"
      log_block "$(printf '[%s] %s[MISS]%s %s/%s 文件不存在\n           期望路径: %s\n           期望 sha256: %s' \
        "$(ts)" "$C_RED" "$C_OFF" "$ver" "$arch" "$dest" "${sha:--}")"
    else
      record FAIL "$ver" "$arch" "HASH 与 Release 不一致"
      log_block "$(printf '[%s] %s[FAIL]%s %s/%s HASH 与 Release 不一致\n           文件: %s\n           期望 sha256: %s' \
        "$(ts)" "$C_RED" "$C_OFF" "$ver" "$arch" "$dest" "${sha:--}")"
    fi
    return 1
  fi

  # ---- 下载到 .part，校验通过再落盘 ----
  local started errfile err
  started=$SECONDS
  errfile="$TMP/curl-$ver-$arch.err"
  rm -f "$part" "$errfile"

  log_block "$(printf '[%s] %s[下载]%s %s/%s\n           来源: %s\n           保存: %s\n           大小: %s 字节（远端 sha256 %s…）' \
    "$(ts)" "$C_BLUE" "$C_OFF" "$ver" "$arch" "$url" "$dest" "$size" "${sha:0:12}")"

  if ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$part" "$url" 2>"$errfile"; then
    err=$(tail -n 1 "$errfile" 2>/dev/null || true)
    rm -f "$part"
    record FAIL "$ver" "$arch" "下载失败：$url ${err}"
    log_block "$(printf '[%s] %s[FAIL]%s %s/%s 下载失败\n           来源: %s\n           原因: %s' \
      "$(ts)" "$C_RED" "$C_OFF" "$ver" "$arch" "$url" "${err:-curl 退出码非 0}")"
    return 1
  fi

  local new_hash new_size elapsed
  new_hash=$(sha256_of "$part")
  if [ -n "$sha" ] && [ "$new_hash" != "$sha" ]; then
    rm -f "$part"
    record FAIL "$ver" "$arch" "下载后 HASH 不匹配（${new_hash:0:12} ≠ ${sha:0:12}）"
    log_block "$(printf '[%s] %s[FAIL]%s %s/%s 下载后 HASH 不匹配\n           临时文件: %s（已丢弃）\n           实际 sha256: %s\n           期望 sha256: %s' \
      "$(ts)" "$C_RED" "$C_OFF" "$ver" "$arch" "$part" "$new_hash" "$sha")"
    return 1
  fi

  chmod 0755 "$part" 2>/dev/null || true
  if ! mv -f "$part" "$dest"; then
    record FAIL "$ver" "$arch" "移动文件失败：$part -> $dest"
    log_block "$(printf '[%s] %s[FAIL]%s %s/%s 移动文件失败: %s -> %s' \
      "$(ts)" "$C_RED" "$C_OFF" "$ver" "$arch" "$part" "$dest")"
    return 1
  fi

  new_size=$(file_size "$dest")
  elapsed=$((SECONDS - started))
  record OK "$ver" "$arch" "下载完成（${new_hash:0:12}，${new_size} 字节，${elapsed}s）"
  log_block "$(printf '[%s] %s[ OK ]%s %s/%s 下载完成\n           保存: %s\n           大小: %s 字节\n           sha256: %s\n           耗时: %s 秒' \
    "$(ts)" "$C_GREEN" "$C_OFF" "$ver" "$arch" "$dest" "$new_size" "$new_hash" "$elapsed")"
}

# ---------------------------------------------------------------------------
# 拉取 Release 清单
# ---------------------------------------------------------------------------
MANIFEST="$TMP/manifest.tsv"
: > "$MANIFEST"

page=1
found_pages=0
while :; do
  f="$TMP/releases.$page.json"
  if ! api_get "$API/repos/$REPO/releases?per_page=100&page=$page" "$f"; then
    rm -f "$f"
    if [ "$found_pages" = 0 ]; then
      if [ "$VERIFY_ONLY" = 1 ]; then
        warn "GitHub API 不可用，回退到本地 SHA256SUMS 校验"
        API_FAILED=1
        break
      fi
      die "无法访问 GitHub API：$API/repos/$REPO/releases"
    fi
    break
  fi
  count=$(json_len "$f") || count=0
  if [ "$count" = 0 ]; then rm -f "$f"; break; fi
  found_pages=$((found_pages + 1))
  python3 -c '
import json, sys
for rel in json.load(open(sys.argv[1])):
    if rel.get("draft"):
        continue
    tag = rel.get("tag_name") or ""
    ver = tag[len("release-"):] if tag.startswith("release-") else tag
    for a in rel.get("assets") or []:
        name = a.get("name") or ""
        if not name.startswith("kubeadm-"):
            continue
        digest = a.get("digest") or ""
        sha = digest.split(":", 1)[1] if digest.startswith("sha256:") else ""
        print("\t".join([ver, name[len("kubeadm-"):], name, str(a.get("size") or 0),
                         sha, a.get("browser_download_url") or ""]))
' "$f" >> "$MANIFEST"
  rm -f "$f"
  [ "$count" -lt 100 ] && break
  page=$((page + 1))
done

API_FAILED="${API_FAILED:-0}"

# ---------------------------------------------------------------------------
# 本地 SHA256SUMS 回退校验（API 不可用且 --verify-only 时）
# ---------------------------------------------------------------------------
if [ "$API_FAILED" = 1 ]; then
  rc=0; checked=0
  for sums in "$OUT_DIR"/*/SHA256SUMS; do
    [ -f "$sums" ] || continue
    dir=$(dirname "$sums")
    info "${C_BLUE}==>${C_OFF} 校验 $(basename "$dir")/SHA256SUMS"
    while read -r want rel; do
      [ -n "${want:-}" ] || continue
      f="$dir/$rel"
      if [ ! -f "$f" ]; then
        error "  [MISS] $rel 不存在"; rc=1; continue
      fi
      got=$(sha256_of "$f")
      if [ "$got" = "$want" ]; then
        info "  ${C_GREEN}[ OK ]${C_OFF} $rel"
      else
        error "  [FAIL] $rel HASH 不一致"; rc=1
      fi
      checked=$((checked + 1))
    done < "$sums"
  done
  info ""
  info "共校验 $checked 个文件"
  exit $rc
fi

# ---------------------------------------------------------------------------
# 过滤
# ---------------------------------------------------------------------------
if [ -n "$VERSION_REGEX" ] || [ -n "$ARCH_FILTER" ]; then
  awk -F'\t' -v vr="$VERSION_REGEX" -v ar="$ARCH_FILTER" '
    (vr == "" || $1 ~ vr) && (ar == "" || $2 == ar) { print }
  ' "$MANIFEST" > "$MANIFEST.filtered"
  mv "$MANIFEST.filtered" "$MANIFEST"
fi

total=$(wc -l < "$MANIFEST" | tr -d ' ')
[ "$total" -gt 0 ] || die "没有匹配到任何产物（检查 --version-regex / --arch 或 Release 是否已发布）"
info "${C_BLUE}==>${C_OFF} 待处理产物：$total 个（并发 $JOBS）"
info ""

# ---------------------------------------------------------------------------
# 逐条处理
# ---------------------------------------------------------------------------
while IFS=$'\t' read -r ver arch name size sha url; do
  do_one "$ver" "$arch" "$(proxy_url "$url")" "$sha" "$size" &
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do
    sleep 0.2
  done
done < "$MANIFEST"
wait

# ---------------------------------------------------------------------------
# 生成每个版本的 SHA256SUMS（只校验模式下不重新生成，避免用损坏文件覆盖校验基准）
# ---------------------------------------------------------------------------
if [ "$LIST_ONLY" = 0 ] && [ "$VERIFY_ONLY" = 0 ]; then
  info ""
  info "${C_BLUE}==>${C_OFF} 生成 SHA256SUMS"
  awk -F'\t' '{print $1}' "$MANIFEST" | sort -u | while read -r ver; do
    vdir="$OUT_DIR/$ver"
    [ -d "$vdir" ] || continue
    tmp="$vdir/.SHA256SUMS.tmp"
    : > "$tmp"
    found=0
    for f in "$vdir"/*/kubeadm; do
      [ -f "$f" ] || continue
      rel="${f#$vdir/}"
      printf '%s  %s\n' "$(sha256_of "$f")" "$rel" >> "$tmp"
      found=$((found + 1))
    done
    if [ "$found" -gt 0 ]; then
      mv -f "$tmp" "$vdir/SHA256SUMS"
      info "  $ver/SHA256SUMS（$found 个文件）"
    else
      rm -f "$tmp"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
ok=$(grep -c '^OK' "$RESULTS" 2>/dev/null || true)
skip=$(grep -c '^SKIP' "$RESULTS" 2>/dev/null || true)
redo=$(grep -c '^REDO' "$RESULTS" 2>/dev/null || true)
fail=$(grep -c '^FAIL' "$RESULTS" 2>/dev/null || true)
miss=$(grep -c '^MISSING' "$RESULTS" 2>/dev/null || true)

info ""
info "${C_BLUE}==>${C_OFF} 汇总：下载 $ok，已存在跳过 $skip，HASH 不一致重下 $redo，失败 $fail，缺失 $miss"
info "    输出目录：$OUT_DIR"
[ -n "$LOG_FILE" ] && info "    日志文件：$LOG_FILE"

if [ "$LIST_ONLY" = 0 ]; then
  info ""
  info "${C_BLUE}==>${C_OFF} 产物布局"
  for vdir in "$OUT_DIR"/*/; do
    [ -d "$vdir" ] || continue
    ver=$(basename "$vdir")
    arches=""
    n=0
    for f in "$vdir"*/kubeadm; do
      [ -f "$f" ] || continue
      a=$(basename "$(dirname "$f")")
      arches="$arches $a"
      n=$((n + 1))
    done
    if [ "$n" -gt 0 ]; then
      printf '    %s: %s 个架构（%s ）\n' "$ver" "$n" "${arches# }"
    fi
  done
fi

if [ "$fail" != 0 ] || [ "$miss" != 0 ]; then
  info "失败明细："
  grep -E '^(FAIL|MISSING)' "$RESULTS" | while IFS=$'\t' read -r st v a msg; do
    printf '  %s %s/%s %s\n' "$st" "$v" "$a" "$msg"
  done
fi

# ---------------------------------------------------------------------------
# 检查哪些标签还没有 Release（CI 尚未跑完时很有用）
# ---------------------------------------------------------------------------
if [ "$CHECK_TAGS" = 1 ] && [ "$LIST_ONLY" = 0 ] && [ "$API_FAILED" = 0 ]; then
  TAGS="$TMP/tags.txt"
  : > "$TAGS"
  page=1
  while :; do
    f="$TMP/tags.$page.json"
    if ! api_get "$API/repos/$REPO/tags?per_page=100&page=$page" "$f"; then rm -f "$f"; break; fi
    count=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("\n".join(t.get("name", "") for t in d))
' "$f" > "$TAGS.$page" && json_len "$f") || count=0
    cat "$TAGS.$page" >> "$TAGS"
    rm -f "$f" "$TAGS.$page"
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
  if [ -s "$TAGS" ]; then
    awk -F'\t' '{print $1}' "$MANIFEST" | sort -u > "$TMP/released.txt"
    missing=$(sort -u "$TAGS" | while read -r t; do
      case "$t" in release-*) ;; *) continue ;; esac
      v="${t#release-}"
      if [ -n "$VERSION_REGEX" ] && ! printf '%s' "$v" | grep -Eq "$VERSION_REGEX"; then continue; fi
      grep -qx "$v" "$TMP/released.txt" || printf '%s ' "$v"
    done)
    if [ -n "$missing" ]; then
      info ""
      info "${C_YELLOW}==>${C_OFF} 以下标签还没有 Release 产物（CI 可能还没跑完）："
      printf '  %s\n' "$missing"
    fi
  fi
fi

if [ "$fail" != 0 ] || [ "$miss" != 0 ]; then
  exit 1
fi
exit 0

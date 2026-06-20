#!/bin/sh

set -eu

B2_FEED_BASE_URL="https://kenzo111.s3.us-west-004.backblazeb2.com/openwrt-feed/daed"
B2_FEED_FALLBACK_URL="https://down.dllkids.xyz/openwrt-feed/daed"
GITHUB_API_URL="https://api.github.com/repos/kenzok8/openwrt-daede/releases/latest"
GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX:-https://ghfast.top/}"
TMP_DIR="/tmp/daede-install"

# Which core backend to install alongside the LuCI app. daed ships the WebUI
# and is the default the LuCI app expects. Override with DAEDE_CORE=dae|daed|both.
DAEDE_CORE="${DAEDE_CORE:-daed}"

fetch_text() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" 2>/dev/null
    return $?
  fi
  wget -qO- "$url" 2>/dev/null
}

download_file() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$out"
    return $?
  fi
  wget -qO "$out" "$url"
}

download_url() {
  url="$1"
  case "$url" in
    https://github.com/*)
      printf '%s%s\n' "$GITHUB_PROXY_PREFIX" "$url"
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

detect_manager() {
  if command -v opkg >/dev/null 2>&1; then echo opkg; return; fi
  if command -v apk >/dev/null 2>&1; then echo apk; return; fi
  echo "unsupported"
}

detect_arch() {
  pm="$1"
  if [ "$pm" = "opkg" ]; then
    opkg print-architecture | awk '/^arch / {print $2}' | tail -n 1
    return
  fi
  # apk --print-arch only returns the CPU family (e.g. aarch64), dropping the
  # subtarget suffix; feed/release use the full target arch (aarch64_cortex-a53),
  # so prefer DISTRIB_ARCH.
  distrib_arch="$(sed -n "s/^DISTRIB_ARCH=['\"]\([^'\"]*\)['\"].*/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1)"
  if [ -n "$distrib_arch" ]; then
    printf '%s\n' "$distrib_arch"
  else
    apk --print-arch
  fi
}

detect_sdk() {
  if [ ! -r /etc/openwrt_release ]; then return 1; fi
  release="$(sed -n "s/^DISTRIB_RELEASE=['\"]\\([^'\"]*\\)['\"]$/\\1/p" /etc/openwrt_release | head -n 1)"
  [ -n "$release" ] || return 1
  sdk="$(printf '%s\n' "$release" | grep -Eo '[0-9]+\.[0-9]+' | head -n 1)"
  [ -n "$sdk" ] || return 1
  printf '%s\n' "$sdk"
}

# Two B2-compatible bases tried per SDK/arch: primary B2 bucket, then the
# dllkids mirror (reachable from mainland China when B2 is blocked).
feed_bases() {
  printf '%s\n%s\n' "$B2_FEED_BASE_URL" "$B2_FEED_FALLBACK_URL"
}

feed_base_for() {
  printf '%s/%s/%s' "$1" "$2" "$3"
}

# Which packages to fetch, in install order (core before luci so opkg/apk can
# resolve the luci-app-daede -> core dependency from local files).
wanted_pkgs() {
  case "$DAEDE_CORE" in
    dae)  printf 'dae\nluci-app-daede\n' ;;
    both) printf 'dae\ndaed\nluci-app-daede\n' ;;
    *)    printf 'daed\nluci-app-daede\n' ;;
  esac
}

# Globals filled by the resolver: space-separated list of "pkg|url|sha256".
PLAN=""
MANIFEST_TEXT=""

manifest_value() {
  printf '%s\n' "$MANIFEST_TEXT" | sed -n "s/^$1=//p" | head -n 1
}

# Resolve every wanted package from the B2 manifest. Manifest lines look like:
#   dae=dae_..._<arch>.ipk
#   dae_sha256=<hex>           (optional)
#   daed=...
#   luci-app-daede=...
resolve_from_manifest() {
  sdk="$1"
  arch="$2"
  for fb in $(feed_bases); do
    base="$(feed_base_for "$fb" "$sdk" "$arch")"
    MANIFEST_TEXT="$(fetch_text "${base}/manifest-daede.txt" || true)"
    [ -n "$MANIFEST_TEXT" ] || continue

    plan=""
    ok=1
    for pkg in $(wanted_pkgs); do
      file="$(manifest_value "$pkg")"
      if [ -z "$file" ]; then
        echo "Manifest has no entry for '$pkg' on ${sdk}/${arch}"
        ok=0
        break
      fi
      sha="$(manifest_value "${pkg}_sha256")"
      plan="${plan}${pkg}|${base}/${file}|${sha}
"
    done
    [ "$ok" = 1 ] || continue
    PLAN="$plan"
    return 0
  done
  return 1
}

# GitHub release fallback (best effort, no sha256 available there).
resolve_from_github() {
  arch="$1"
  ext="$2"
  payload="$(fetch_text "$GITHUB_API_URL" || true)"
  [ -n "$payload" ] || return 1
  urls="$(printf '%s\n' "$payload" | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$urls" ] || return 1

  plan=""
  for pkg in $(wanted_pkgs); do
    if [ "$pkg" = "luci-app-daede" ]; then
      if [ "$ext" = "apk" ]; then
        url="$(printf '%s\n' "$urls" | grep -E "/luci-app-daede-[^/]*-${arch}\.apk$" | head -n 1)"
      else
        url="$(printf '%s\n' "$urls" | grep -E '/luci-app-daede_.*_all\.ipk$' | head -n 1)"
      fi
    else
      if [ "$ext" = "apk" ]; then
        url="$(printf '%s\n' "$urls" | grep -E "/${pkg}-[^/]*-${arch}\.apk$" | head -n 1)"
      else
        url="$(printf '%s\n' "$urls" | grep -E "/${pkg}_[^/]*_${arch}\.ipk$" | head -n 1)"
      fi
    fi
    if [ -z "$url" ]; then
      echo "GitHub release has no '$pkg' for arch: $arch"
      return 1
    fi
    plan="${plan}${pkg}|${url}|
"
  done
  PLAN="$plan"
  return 0
}

verify_sha256() {
  file="$1"
  want="$2"
  [ -n "$want" ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$file" | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    got="$(openssl dgst -sha256 "$file" | awk '{print $NF}')"
  else
    echo "[WARN] no sha256 tool, skipping checksum for $(basename "$file")"
    return 0
  fi
  if [ "$got" != "$want" ]; then
    echo "Checksum mismatch for $(basename "$file"): expected $want, got $got"
    return 1
  fi
  echo "  sha256 ok: $(basename "$file")"
}

VMLINUX_BTF_API="${VMLINUX_BTF_API:-https://api.github.com/repos/kenzok8/vmlinux-btf/releases/tags/latest}"

# dae/daed load CO-RE eBPF that needs kernel BTF: /sys/kernel/btf/vmlinux when the
# kernel was built with CONFIG_DEBUG_INFO_BTF, else a packaged detached BTF.
btf_available() {
  [ -e /sys/kernel/btf/vmlinux ] && return 0
  [ -e "/usr/lib/debug/boot/vmlinux-$(uname -r)" ] && return 0
  return 1
}

# Fetch a vmlinux-btf matching this kernel + arch when the firmware ships no BTF.
ensure_btf() {
  pm="$1"; arch="$2"
  if btf_available; then
    echo "Kernel BTF present; dae/daed eBPF is ready."
    return 0
  fi

  krel="$(uname -r)"
  kmm="$(printf '%s' "$krel" | grep -Eo '^[0-9]+\.[0-9]+')"
  kver="$(printf '%s' "$krel" | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+')"
  ext="ipk"; [ "$pm" = "apk" ] && ext="apk"

  echo "Kernel BTF missing — dae/daed need it for eBPF. Looking for vmlinux-btf (${arch}, kernel ${kver:-$krel})..."

  urls="$(fetch_text "$VMLINUX_BTF_API" \
    | grep -Eo '"browser_download_url"[^,]*' \
    | sed -E 's/.*"(https[^"]+)".*/\1/' \
    | grep -E "/vmlinux-btf[^/]*\.${ext}$" \
    | grep -F "$arch")"

  url=""
  [ -n "$urls" ] && [ -n "$kver" ] && url="$(printf '%s\n' "$urls" | grep -F "$kver" | head -n 1)"
  [ -z "$url" ] && [ -n "$urls" ] && [ -n "$kmm" ] && url="$(printf '%s\n' "$urls" | grep -E "[_-]${kmm}\.[0-9]+" | head -n 1)"
  [ -z "$url" ] && url="$(printf '%s\n' "$urls" | head -n 1)"

  if [ -z "$url" ]; then
    echo "[WARN] No vmlinux-btf for arch '${arch}', kernel '${krel}'. dae/daed will not start"
    echo "       without kernel BTF. Reflash firmware with CONFIG_DEBUG_INFO_BTF, or build a"
    echo "       matching package: https://github.com/kenzok8/vmlinux-btf"
    return 1
  fi

  out="$TMP_DIR/vmlinux-btf.${ext}"
  echo "Downloading $(basename "$url")..."
  download_file "$(download_url "$url")" "$out" || { echo "[WARN] vmlinux-btf download failed."; return 1; }

  echo "Installing vmlinux-btf..."
  if [ "$pm" = "opkg" ]; then
    opkg install "$out" || { echo "[WARN] vmlinux-btf install failed."; return 1; }
  else
    apk add --allow-untrusted "$out" || { echo "[WARN] vmlinux-btf install failed."; return 1; }
  fi

  if btf_available; then
    echo "vmlinux-btf installed; kernel BTF now available."
  else
    echo "[WARN] vmlinux-btf installed but BTF still missing for kernel ${krel} (series mismatch?)."
  fi
}

PM="$(detect_manager)"
if [ "$PM" = "unsupported" ]; then
  echo "No supported package manager (opkg/apk)."
  exit 1
fi

ARCH="$(detect_arch "$PM")"
[ -n "$ARCH" ] || { echo "Cannot detect architecture"; exit 1; }

EXT="ipk"
[ "$PM" = "apk" ] && EXT="apk"

SDK="$(detect_sdk || true)"

if [ -n "$SDK" ] && resolve_from_manifest "$SDK" "$ARCH"; then
  echo "Using B2 manifest: ${SDK}/${ARCH}"
elif resolve_from_github "$ARCH" "$EXT"; then
  echo "Using GitHub latest release"
else
  echo "Cannot resolve daede packages for arch: $ARCH"
  exit 1
fi

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

FILES=""
echo "$PLAN" | while IFS='|' read -r pkg url sha; do
  [ -n "$pkg" ] || continue
  out="$TMP_DIR/${pkg}.${EXT}"
  echo "Downloading ${pkg}..."
  download_file "$(download_url "$url")" "$out"
  verify_sha256 "$out" "$sha"
done

# The while loop above runs in a subshell (pipe), so rebuild the file list here.
for pkg in $(wanted_pkgs); do
  FILES="$FILES $TMP_DIR/${pkg}.${EXT}"
done

echo "Installing (core first, then LuCI)..."
if [ "$PM" = "opkg" ]; then
  # shellcheck disable=SC2086
  opkg install $FILES
else
  echo "[WARN] no stable signing key yet, using --allow-untrusted; sha256 is verified above when the manifest provides it."
  # shellcheck disable=SC2086
  apk add --allow-untrusted $FILES
fi

echo "Install complete."

# Supply kernel BTF if the firmware ships none, else dae/daed eBPF won't load.
ensure_btf "$PM" "$ARCH" || true

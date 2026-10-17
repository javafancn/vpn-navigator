#!/bin/bash
# Build a native, macOS-13-targeted engine from verified sources. OpenSSL is
# linked statically; no Homebrew dylib or end-user brew installation is needed.
set -euo pipefail
: "${OPENVPN_SOURCE_ARCHIVE:?required}"
: "${OPENVPN_SOURCE_SHA256:?required}"
: "${OPENSSL_SOURCE_ARCHIVE:?required}"
: "${OPENSSL_SOURCE_SHA256:?required}"
: "${ENGINE_OUTPUT_DIR:?required}"
verify_source() {
  [[ "$2" =~ ^[0-9A-Fa-f]{64}$ ]] || exit 1
  printf '%s  %s\n' "$2" "$1" | shasum -a 256 --check
  tar -tzf "$1" >/dev/null
}
verify_source "$OPENVPN_SOURCE_ARCHIVE" "$OPENVPN_SOURCE_SHA256"
verify_source "$OPENSSL_SOURCE_ARCHIVE" "$OPENSSL_SOURCE_SHA256"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS build host required'; exit 1; }
TASK_SOURCE_DIR="$(mktemp -d)"
trap 'rm -rf "$TASK_SOURCE_DIR"' EXIT
mkdir -p "$TASK_SOURCE_DIR/openssl" "$TASK_SOURCE_DIR/openvpn" "$ENGINE_OUTPUT_DIR"
tar -xzf "$OPENSSL_SOURCE_ARCHIVE" -C "$TASK_SOURCE_DIR/openssl" --strip-components=1
tar -xzf "$OPENVPN_SOURCE_ARCHIVE" -C "$TASK_SOURCE_DIR/openvpn" --strip-components=1
ENGINE_OUTPUT_DIR="$(cd "$ENGINE_OUTPUT_DIR" && pwd)"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CC=clang
export CFLAGS='-O2 -mmacosx-version-min=13.0'
export LDFLAGS='-mmacosx-version-min=13.0'
case "$(uname -m)" in
  arm64) SSL_TARGET=darwin64-arm64-cc ;;
  x86_64) SSL_TARGET=darwin64-x86_64-cc ;;
  *) echo 'Unsupported build architecture'; exit 1 ;;
esac
JOBS="$(sysctl -n hw.ncpu)"
[[ "$JOBS" -le 4 ]] || JOBS=4
(
  cd "$TASK_SOURCE_DIR/openssl"
  ./Configure "$SSL_TARGET" no-shared no-tests no-module --prefix="$ENGINE_OUTPUT_DIR" --libdir=lib
  make -j "$JOBS"
  make install_sw
)
(
  cd "$TASK_SOURCE_DIR/openvpn"
  export PKG_CONFIG_PATH="$ENGINE_OUTPUT_DIR/lib/pkgconfig"
  export OPENSSL_CFLAGS="-I$ENGINE_OUTPUT_DIR/include"
  export OPENSSL_LIBS="$ENGINE_OUTPUT_DIR/lib/libssl.a $ENGINE_OUTPUT_DIR/lib/libcrypto.a -framework Security -framework CoreFoundation"
  ./configure --prefix="$ENGINE_OUTPUT_DIR" --with-crypto-library=openssl \
    --disable-lzo --disable-lz4 --disable-pkcs11 --disable-plugin-auth-pam --disable-dco --disable-systemd
  make -j "$JOBS"
  make install
)
"$ENGINE_OUTPUT_DIR/sbin/openvpn" --version
mkdir -p "$ENGINE_OUTPUT_DIR/share/vpn-navigator"
{
  printf 'VPN Navigator source-built OpenVPN engine\n\n'
  printf 'OpenVPN source SHA256: %s\nOpenSSL source SHA256: %s\n' "$OPENVPN_SOURCE_SHA256" "$OPENSSL_SOURCE_SHA256"
  printf 'macOS deployment target: 13.0; native architecture: %s\n' "$(uname -m)"
  printf 'OpenSSL static linking; compression, PKCS11 and PAM plugins disabled.\n\n'
  printf '%s\n' '--- OpenVPN license and exception ---'
  cat "$TASK_SOURCE_DIR/openvpn/COPYING"
  printf '\n%s\n' '--- OpenSSL license ---'
  cat "$TASK_SOURCE_DIR/openssl/LICENSE.txt"
} > "$ENGINE_OUTPUT_DIR/share/vpn-navigator/THIRD_PARTY_NOTICES.txt"
echo "Built $ENGINE_OUTPUT_DIR/sbin/openvpn"

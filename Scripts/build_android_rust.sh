#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$APP_DIR/Rust/core"
RUST_DIR="$APP_DIR/Rust"

if [[ "${GOOSE_SKIP_RUST_CORE_BUILD:-0}" == "1" ]]; then
  echo "Skipping Goose Rust core build because GOOSE_SKIP_RUST_CORE_BUILD=1"
  exit 0
fi

ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-23}"
CONFIGURATION="${CONFIGURATION:-Debug}"

if [[ "${GOOSE_RUST_RELEASE:-0}" == "1" ]]; then
  CARGO_RELEASE=1
  CARGO_PROFILE_DIR="release"
elif [[ "$CONFIGURATION" == "Release" || "$CONFIGURATION" == "Profile" ]]; then
  CARGO_RELEASE=1
  CARGO_PROFILE_DIR="release"
else
  CARGO_RELEASE=0
  CARGO_PROFILE_DIR="debug"
fi

find_android_ndk() {
  if [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]]; then
    printf '%s\n' "$ANDROID_NDK_HOME"
    return
  fi
  if [[ -n "${ANDROID_NDK_ROOT:-}" && -d "$ANDROID_NDK_ROOT" ]]; then
    printf '%s\n' "$ANDROID_NDK_ROOT"
    return
  fi
  if [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME/ndk" ]]; then
    find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
    return
  fi
  if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT/ndk" ]]; then
    find "$ANDROID_SDK_ROOT/ndk" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
    return
  fi
  if [[ -d "$HOME/Library/Android/sdk/ndk" ]]; then
    find "$HOME/Library/Android/sdk/ndk" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
    return
  fi
}

host_tag() {
  case "$(uname -s)" in
    Darwin)
      case "$(uname -m)" in
        arm64) printf '%s\n' "darwin-arm64" ;;
        *) printf '%s\n' "darwin-x86_64" ;;
      esac
      ;;
    Linux)
      printf '%s\n' "linux-x86_64"
      ;;
    *)
      echo "Unsupported Android NDK host: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

toolchain_dir_for_ndk() {
  local ndk_dir="$1"
  local preferred
  preferred="$(host_tag)"
  if [[ -d "$ndk_dir/toolchains/llvm/prebuilt/$preferred" ]]; then
    printf '%s\n' "$ndk_dir/toolchains/llvm/prebuilt/$preferred"
    return
  fi
  case "$preferred" in
    darwin-arm64)
      if [[ -d "$ndk_dir/toolchains/llvm/prebuilt/darwin-x86_64" ]]; then
        printf '%s\n' "$ndk_dir/toolchains/llvm/prebuilt/darwin-x86_64"
        return
      fi
      ;;
  esac
  find "$ndk_dir/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
}

target_for_abi() {
  case "$1" in
    arm64-v8a) printf '%s\n' "aarch64-linux-android" ;;
    armeabi-v7a) printf '%s\n' "armv7-linux-androideabi" ;;
    x86_64) printf '%s\n' "x86_64-linux-android" ;;
    *)
      echo "Unsupported Android ABI: $1" >&2
      exit 1
      ;;
  esac
}

clang_prefix_for_target() {
  case "$1" in
    aarch64-linux-android) printf '%s\n' "aarch64-linux-android" ;;
    armv7-linux-androideabi) printf '%s\n' "armv7a-linux-androideabi" ;;
    x86_64-linux-android) printf '%s\n' "x86_64-linux-android" ;;
    *)
      echo "Unsupported Android Rust target: $1" >&2
      exit 1
      ;;
  esac
}

export_linker_for_target() {
  local rust_target="$1"
  local clang="$2"
  local ar="$3"
  case "$rust_target" in
    aarch64-linux-android)
      export CC_aarch64_linux_android="$clang"
      export AR_aarch64_linux_android="$ar"
      export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$clang"
      ;;
    armv7-linux-androideabi)
      export CC_armv7_linux_androideabi="$clang"
      export AR_armv7_linux_androideabi="$ar"
      export CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="$clang"
      ;;
    x86_64-linux-android)
      export CC_x86_64_linux_android="$clang"
      export AR_x86_64_linux_android="$ar"
      export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$clang"
      ;;
    *)
      echo "Unsupported Android Rust target: $rust_target" >&2
      exit 1
      ;;
  esac
}

NDK_DIR="$(find_android_ndk || true)"
if [[ -z "$NDK_DIR" ]]; then
  echo "Android NDK not found. Set ANDROID_NDK_HOME, ANDROID_NDK_ROOT, ANDROID_HOME, or ANDROID_SDK_ROOT." >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "Cargo not found. Install Rust via rustup before building the Goose Rust core." >&2
  exit 1
fi

TOOLCHAIN_DIR="$(toolchain_dir_for_ndk "$NDK_DIR")"
if [[ ! -d "$TOOLCHAIN_DIR" ]]; then
  echo "Android NDK LLVM toolchain not found under $NDK_DIR/toolchains/llvm/prebuilt" >&2
  exit 1
fi

IFS=' ' read -r -a ANDROID_ABIS_ARRAY <<< "${ANDROID_ABIS:-arm64-v8a armeabi-v7a x86_64}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$APP_DIR/build/rust-target/goose-core-android}"

for abi in "${ANDROID_ABIS_ARRAY[@]}"; do
  rust_target="$(target_for_abi "$abi")"
  clang_prefix="$(clang_prefix_for_target "$rust_target")"
  clang="$TOOLCHAIN_DIR/bin/${clang_prefix}${ANDROID_API_LEVEL}-clang"
  ar="$TOOLCHAIN_DIR/bin/llvm-ar"

  if [[ ! -x "$clang" ]]; then
    echo "Android clang not found or not executable: $clang" >&2
    exit 1
  fi
  if [[ ! -x "$ar" ]]; then
    echo "Android llvm-ar not found or not executable: $ar" >&2
    exit 1
  fi

  export_linker_for_target "$rust_target" "$clang" "$ar"

  cargo_args=(
    build
    --lib
    --manifest-path "$CORE_DIR/Cargo.toml"
    --target "$rust_target"
  )
  if [[ "$CARGO_RELEASE" == "1" ]]; then
    cargo_args+=(--release)
  fi

  cargo "${cargo_args[@]}"

  platform_rust_dir="$RUST_DIR/android/$abi"
  output_lib="$platform_rust_dir/libgoose_core.so"
  mkdir -p "$platform_rust_dir"
  cp "$CARGO_TARGET_DIR/$rust_target/$CARGO_PROFILE_DIR/libgoose_core.so" "$output_lib"
  printf '%s\n' "$rust_target" > "$platform_rust_dir/.goose_core.target"
  printf '%s\n' "$CARGO_PROFILE_DIR" > "$platform_rust_dir/.goose_core.profile"

  echo "Built Goose Rust Android library for $abi / $rust_target ($CARGO_PROFILE_DIR) at $output_lib"
done

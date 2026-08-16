#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SHERPA_UPSTREAM_VERSION="1.13.5"
SHERPA_UPSTREAM_COMMIT="3dc7c569f31ca2cd4a20ed6f7db780327e6714c5"
ONNX_RUNTIME_VERSION="1.28.0"
ONNX_RUNTIME_COMMIT="da9b5e364c465de65c49d91e696cd6485270757f"
ONNX_RUNTIME_AAR_SHA256="f351a0638696f54b35184290dbc001d66daae17281ad0b548d2c70347d53b8a9"
RUNANYWHERE_RELEASE_TAG="${RUNANYWHERE_RELEASE_TAG:-v1.13.5-rac.4}"
OUTPUT_DIR="${RUNANYWHERE_OUTPUT_DIR:-${REPO_ROOT}/dist}"
REUSE_BUILD="${RUNANYWHERE_REUSE_BUILD:-0}"

if [ -z "${ANDROID_NDK:-}" ] || [ ! -d "${ANDROID_NDK}" ]; then
  printf 'ANDROID_NDK must point to an installed Android NDK.\n' >&2
  exit 1
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

TEMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

ONNX_AAR="${TEMP_DIR}/onnxruntime-android-${ONNX_RUNTIME_VERSION}.aar"
ONNX_ROOT="${TEMP_DIR}/onnxruntime-android-${ONNX_RUNTIME_VERSION}"
ONNX_URL="https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/${ONNX_RUNTIME_VERSION}/onnxruntime-android-${ONNX_RUNTIME_VERSION}.aar"

curl --fail --location --silent --show-error --retry 5 \
  --output "${ONNX_AAR}" "${ONNX_URL}"
actual_onnx_sha256="$(sha256_file "${ONNX_AAR}")"
if [ "${actual_onnx_sha256}" != "${ONNX_RUNTIME_AAR_SHA256}" ]; then
  printf 'ONNX Runtime AAR SHA-256 mismatch: expected %s, got %s\n' \
    "${ONNX_RUNTIME_AAR_SHA256}" "${actual_onnx_sha256}" >&2
  exit 1
fi
mkdir -p "${ONNX_ROOT}"
unzip -q "${ONNX_AAR}" -d "${ONNX_ROOT}"

# Android's CMake toolchain overwrites CFLAGS/CXXFLAGS while initializing the
# compiler. Inject the reproducibility maps as cache values instead, without
# patching any of Sherpa's upstream per-ABI build scripts.
REAL_CMAKE="$(command -v cmake)"
CMAKE_WRAPPER_DIR="${TEMP_DIR}/cmake-wrapper"
mkdir -p "${CMAKE_WRAPPER_DIR}"
cat > "${CMAKE_WRAPPER_DIR}/cmake" <<'EOF'
#!/usr/bin/env bash
exec "${RUNANYWHERE_REAL_CMAKE}" \
  "-DCMAKE_C_FLAGS=${RUNANYWHERE_PREFIX_MAP_FLAGS}" \
  "-DCMAKE_CXX_FLAGS=${RUNANYWHERE_PREFIX_MAP_FLAGS}" \
  "$@"
EOF
chmod +x "${CMAKE_WRAPPER_DIR}/cmake"
export RUNANYWHERE_REAL_CMAKE="${REAL_CMAKE}"
export RUNANYWHERE_PREFIX_MAP_FLAGS="-ffile-prefix-map=${REPO_ROOT}=/runanywhere-sherpa-onnx \
-fmacro-prefix-map=${REPO_ROOT}=/runanywhere-sherpa-onnx \
-fdebug-prefix-map=${REPO_ROOT}=/runanywhere-sherpa-onnx"
export PATH="${CMAKE_WRAPPER_DIR}:${PATH}"

readelf_candidates=("${ANDROID_NDK}"/toolchains/llvm/prebuilt/*/bin/llvm-readelf)
READELF="${readelf_candidates[0]}"
if [ ! -x "${READELF}" ]; then
  printf 'llvm-readelf was not found under %s\n' "${ANDROID_NDK}" >&2
  exit 1
fi

STAGE_NAME="sherpa-onnx-${RUNANYWHERE_RELEASE_TAG}-android"
STAGE_ROOT="${TEMP_DIR}/${STAGE_NAME}"
mkdir -p "${STAGE_ROOT}/jniLibs"

build_abi() {
  local abi="$1"
  local build_script="$2"
  local build_dir="$3"

  if [ "${REUSE_BUILD}" != "1" ]; then
    rm -rf "${REPO_ROOT:?}/${build_dir}"
  fi

  env \
    ANDROID_NDK="${ANDROID_NDK}" \
    SHERPA_ONNX_ONNXRUNTIME_ROOT="${ONNX_ROOT}" \
    SHERPA_ONNX_ENABLE_C_API=ON \
    SHERPA_ONNX_ENABLE_TTS=ON \
    SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=ON \
    BUILD_SHARED_LIBS=ON \
    "${REPO_ROOT}/${build_script}"

  local source_dir="${REPO_ROOT}/${build_dir}/install/lib"
  local destination_dir="${STAGE_ROOT}/jniLibs/${abi}"
  mkdir -p "${destination_dir}"
  cp \
    "${source_dir}/libonnxruntime.so" \
    "${source_dir}/libsherpa-onnx-c-api.so" \
    "${source_dir}/libsherpa-onnx-jni.so" \
    "${destination_dir}/"
}

build_abi arm64-v8a build-android-arm64-v8a.sh build-android-arm64-v8a
build_abi armeabi-v7a build-android-armv7-eabi.sh build-android-armv7-eabi
build_abi x86_64 build-android-x86-64.sh build-android-x86-64
build_abi x86 build-android-x86.sh build-android-x86

library_count=0
while IFS= read -r -d '' library; do
  library_count=$((library_count + 1))
  load_count=0
  while IFS= read -r alignment; do
    [ -n "${alignment}" ] || continue
    load_count=$((load_count + 1))
    if (( alignment < 0x4000 )); then
      printf '%s has PT_LOAD alignment %s; expected at least 0x4000\n' \
        "${library}" "${alignment}" >&2
      exit 1
    fi
  done < <("${READELF}" -W -l "${library}" | awk '$1 == "LOAD" {print $NF}')
  if [ "${load_count}" -eq 0 ]; then
    printf '%s has no readable PT_LOAD segments\n' "${library}" >&2
    exit 1
  fi
  if LC_ALL=C grep -aEq '/Users/|/home/|/var/folders/|[A-Z]:\\Users\\' "${library}"; then
    printf '%s contains an absolute host build path\n' "${library}" >&2
    exit 1
  fi
done < <(find "${STAGE_ROOT}/jniLibs" -type f -name '*.so' -print0)

if [ "${library_count}" -ne 12 ]; then
  printf 'Expected 12 Android shared libraries, found %d\n' "${library_count}" >&2
  exit 1
fi

source_commit="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
patch_sha256="$(git -C "${REPO_ROOT}" diff "${SHERPA_UPSTREAM_COMMIT}" HEAD -- \
  sherpa-onnx/csrc/offline-recognizer-whisper-impl.h \
  sherpa-onnx/csrc/offline-whisper-greedy-search-decoder.cc \
  sherpa-onnx/csrc/offline-whisper-model-config.h | sha256_file /dev/stdin)"
printf '%s\n' \
  "release_tag=${RUNANYWHERE_RELEASE_TAG}" \
  "source_commit=${source_commit}" \
  "upstream_version=${SHERPA_UPSTREAM_VERSION}" \
  "upstream_commit=${SHERPA_UPSTREAM_COMMIT}" \
  "patch_sha256=${patch_sha256}" \
  "onnxruntime_version=${ONNX_RUNTIME_VERSION}" \
  "onnxruntime_commit=${ONNX_RUNTIME_COMMIT}" \
  "onnxruntime_aar_sha256=${ONNX_RUNTIME_AAR_SHA256}" \
  > "${STAGE_ROOT}/PROVENANCE.txt"

mkdir -p "${OUTPUT_DIR}"
ARCHIVE="${OUTPUT_DIR}/${STAGE_NAME}.tar.bz2"
tar -C "${TEMP_DIR}" -cjf "${ARCHIVE}" "${STAGE_NAME}"
printf 'Created %s\n' "${ARCHIVE}"
printf 'SHA-256: %s\n' "$(sha256_file "${ARCHIVE}")"

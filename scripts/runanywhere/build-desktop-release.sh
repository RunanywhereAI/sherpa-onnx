#!/usr/bin/env bash

set -euo pipefail

readonly SHERPA_VERSION="1.13.5"
readonly SHERPA_COMMIT="3dc7c569f31ca2cd4a20ed6f7db780327e6714c5"
readonly ONNX_VERSION="1.28.0"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_root="${repo_root}/build-runanywhere-desktop"
dist_dir="${repo_root}/dist"
download_dir="${build_root}/downloads"

actual_commit="$(git -C "${repo_root}" rev-parse HEAD)"
if ! git -C "${repo_root}" merge-base --is-ancestor "${SHERPA_COMMIT}" "${actual_commit}"; then
  printf 'error: upstream Sherpa commit %s is not an ancestor of %s\n' \
    "${SHERPA_COMMIT}" "${actual_commit}" >&2
  exit 1
fi

case "$(uname -s)" in
  Linux)
    case "$(uname -m)" in
      x86_64)
        platform="linux-x64"
        ort_asset="onnxruntime-linux-x64-${ONNX_VERSION}.tgz"
        ort_sha256="a3e1b79d7bb1bf09696ce675f49e4064e6c81f6202b8225624fff0e93f8d6407"
        ;;
      aarch64|arm64)
        platform="linux-aarch64"
        ort_asset="onnxruntime-linux-aarch64-${ONNX_VERSION}.tgz"
        ort_sha256="e15ff8b5d85afe6c144d97c6fd432254bf76a219daaf17658087d6ecb3e8f0bb"
        ;;
      *)
        printf 'error: unsupported Linux architecture %s\n' "$(uname -m)" >&2
        exit 1
        ;;
    esac
    ;;
  MINGW*|MSYS*|CYGWIN*)
    platform="win-x64"
    ort_asset="onnxruntime-win-x64-${ONNX_VERSION}.zip"
    ort_sha256="abef733dacbe2f571547a7150b479b5cb9cc0df22f96c24983a42cadb1b4f8bc"
    ;;
  *)
    printf 'error: unsupported host %s\n' "$(uname -s)" >&2
    exit 1
    ;;
esac

mkdir -p "${download_dir}" "${dist_dir}"
ort_archive="${download_dir}/${ort_asset}"
curl --fail --location --show-error --silent --retry 5 \
  --output "${ort_archive}" \
  "https://github.com/microsoft/onnxruntime/releases/download/v${ONNX_VERSION}/${ort_asset}"
printf '%s  %s\n' "${ort_sha256}" "${ort_archive}" | sha256sum --check --strict

if [[ "${ort_asset}" == *.zip ]]; then
  7z x -y "${ort_archive}" "-o${download_dir}"
else
  tar -xzf "${ort_archive}" -C "${download_dir}"
fi
ort_root="${download_dir}/${ort_asset%.tgz}"
ort_root="${ort_root%.zip}"
if [[ ! -f "${ort_root}/include/onnxruntime_c_api.h" ]]; then
  printf 'error: ONNX Runtime archive has an unexpected layout\n' >&2
  exit 1
fi

cmake_args=(
  -S "${repo_root}"
  -B "${build_root}/build"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${build_root}/install"
  -DBUILD_SHARED_LIBS=ON
  -DSHERPA_ONNX_ENABLE_C_API=ON
  -DSHERPA_ONNX_ENABLE_BINARY=OFF
  -DSHERPA_ONNX_ENABLE_TESTS=OFF
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF
  -DSHERPA_ONNX_ENABLE_GPU=OFF
  -DSHERPA_ONNX_ENABLE_TTS=ON
)

if [[ "${platform}" == win-* ]]; then
  ort_root="$(cygpath -m "${ort_root}")"
  source_root_for_compiler="$(cygpath -m "${repo_root}")"
  cmake_args+=(
    -A x64
    -DSHERPA_ONNX_USE_STATIC_CRT=ON
    -DBUILD_ESPEAK_NG_EXE=OFF
    "-DCMAKE_C_FLAGS=/experimental:deterministic /Brepro /pathmap:${source_root_for_compiler}=C:/runanywhere/vendor/sherpa-onnx"
    "-DCMAKE_CXX_FLAGS=/experimental:deterministic /Brepro /pathmap:${source_root_for_compiler}=C:/runanywhere/vendor/sherpa-onnx"
  )
else
  prefix_flags="-ffile-prefix-map=${repo_root}=/runanywhere/vendor/sherpa-onnx -fmacro-prefix-map=${repo_root}=/runanywhere/vendor/sherpa-onnx -fdebug-prefix-map=${repo_root}=/runanywhere/vendor/sherpa-onnx"
  cmake_args+=(
    "-DCMAKE_C_FLAGS=${prefix_flags}"
    "-DCMAKE_CXX_FLAGS=${prefix_flags}"
  )
fi

export SHERPA_ONNXRUNTIME_LIB_DIR="${ort_root}/lib"
export SHERPA_ONNXRUNTIME_INCLUDE_DIR="${ort_root}/include"
cmake "${cmake_args[@]}"
cmake --build "${build_root}/build" --config Release --parallel 2
cmake --build "${build_root}/build" --config Release --target install --parallel 2

package_name="sherpa-onnx-v${SHERPA_VERSION}-${platform}-shared-rac-ort${ONNX_VERSION}"
package_dir="${build_root}/${package_name}"
mkdir -p "${package_dir}"
cp -R "${build_root}/install/." "${package_dir}/"
mkdir -p "${package_dir}/lib" "${package_dir}/include"
cp -R "${ort_root}/include/." "${package_dir}/include/"

if [[ "${platform}" == win-* ]]; then
  cp "${ort_root}/lib/onnxruntime.dll" "${package_dir}/lib/"
  cp "${ort_root}/lib/onnxruntime.lib" "${package_dir}/lib/"
  if [[ ! -f "${package_dir}/lib/sherpa-onnx-c-api.dll" ]]; then
    printf 'error: packaged Windows Sherpa C API DLL is missing\n' >&2
    exit 1
  fi
else
  cp -a "${ort_root}/lib/"libonnxruntime.so* "${package_dir}/lib/"
  if [[ ! -f "${package_dir}/lib/libsherpa-onnx-c-api.so" ]]; then
    printf 'error: packaged Linux Sherpa C API library is missing\n' >&2
    exit 1
  fi
  readelf -d "${package_dir}/lib/libsherpa-onnx-c-api.so"
  readelf --version-info "${package_dir}/lib/libonnxruntime.so.${ONNX_VERSION}" | grep -F "VERS_${ONNX_VERSION}"
fi

cat > "${package_dir}/PROVENANCE.txt" <<EOF
sherpa_onnx_version=${SHERPA_VERSION}
sherpa_onnx_upstream_commit=${SHERPA_COMMIT}
runanywhere_source_commit=${actual_commit}
onnxruntime_version=${ONNX_VERSION}
onnxruntime_asset=${ort_asset}
onnxruntime_sha256=${ort_sha256}
platform=${platform}
EOF

if LC_ALL=C grep -aErq \
  '/home/runner/|/Users/[^/]+/|[A-Za-z]:[/\\]Users[/\\]|[A-Za-z]:[/\\]a[/\\]sherpa-onnx[/\\]sherpa-onnx' \
  "${package_dir}/bin" "${package_dir}/lib"; then
  printf 'error: packaged desktop runtime embeds a build-host path\n' >&2
  exit 1
fi

archive="${dist_dir}/${package_name}.tar.bz2"
if [[ "${platform}" == win-* ]]; then
  archive_tar="${archive%.bz2}"
  (cd "${build_root}" && 7z a -y -ttar "${archive_tar}" "${package_name}")
  7z a -y -tbzip2 "${archive}" "${archive_tar}"
else
  tar -cjf "${archive}" -C "${build_root}" "${package_name}"
fi

sha256sum "${archive}"

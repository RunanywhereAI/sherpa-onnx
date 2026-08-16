# RunAnywhere Android fork

This fork tracks upstream sherpa-onnx and carries one Android-required behavior
delta: Whisper greedy decoding retains the selected token's log probability so
RunAnywhere can compute transcript confidence for its cloud-fallback router.

The current release line is based on upstream `v1.13.5`
(`3dc7c569f31ca2cd4a20ed6f7db780327e6714c5`) and is built against ONNX Runtime
`v1.29.0` (`2e2543fbe9fae542f921d47a72d21d5a4ef0b710`). The public Sherpa C API is
unchanged; the patch only fills the existing `ys_log_probs` result field for
Whisper.

Build and validate the four-ABI Android release archive with:

```bash
ANDROID_NDK=/path/to/android-ndk-r27d \
  ./scripts/runanywhere/build-android-release.sh
```

The script verifies the ONNX Runtime AAR checksum, builds `arm64-v8a`,
`armeabi-v7a`, `x86_64`, and `x86`, enforces 16 KiB ELF load-segment alignment,
rejects embedded host paths, and writes the release archive under `dist/`.
The `runanywhere-android-release` workflow performs the same build and publishes
the archive when a `v*-rac.*` tag is pushed.

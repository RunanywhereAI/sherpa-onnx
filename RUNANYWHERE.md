# RunAnywhere Sherpa ONNX fork

This fork tracks upstream sherpa-onnx and carries one Android-required behavior
delta: Whisper greedy decoding retains the selected token's log probability so
RunAnywhere can compute transcript confidence for its cloud-fallback router;
the Windows pre-installed-ORT path also assigns both the runtime DLL and import
library so CPU-only shared builds configure correctly.

The current release line is based on upstream `v1.13.5`
(`3dc7c569f31ca2cd4a20ed6f7db780327e6714c5`) and is built against ONNX Runtime
`v1.28.0` (`da9b5e364c465de65c49d91e696cd6485270757f`). This is the newest ORT release
with the static Apple and Web artifacts needed to keep every RunAnywhere SDK
target on one ABI baseline. The public Sherpa C API is unchanged; the patch
only fills the existing `ys_log_probs` result field for Whisper.

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

Linux x64, Linux arm64, and Windows x64 releases are built from this same source
against exact official ONNX Runtime 1.28.0 archives. Run them locally with
`scripts/runanywhere/build-desktop-release.sh`; the
`runanywhere-desktop-release` workflow publishes all three artifacts for a
`v*-rac-desktop.*` tag. Desktop builds use deterministic source-prefix maps and
the release fails closed if any packaged binary still contains a build-host
path.

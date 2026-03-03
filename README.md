# Ziggurat Builder

This repo builds a hermetic Zig + LLVM toolchain bundle for downstream Bazel toolchains.

The build:
- resolves the latest official Zig release (or a pinned `ZIG_REF`),
- derives the matching LLVM version from that Zig release,
- resolves the matching `include-what-you-use` `clang_<major>` branch,
- builds LLVM, Zig, mold, and iwyu into one packaged payload.

Output:
- `dist/ziggurat-<zig-version>.tar.xz`
- `dist/build-info.txt`

Primary entrypoint:
- `./build-toolchain.sh`

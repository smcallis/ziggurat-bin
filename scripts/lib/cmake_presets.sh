#!/usr/bin/env bash
set -euo pipefail

## Return default LLVM projects to build.
default_llvm_projects() {
	echo "clang;clang-tools-extra;lld"
}

## Return default LLVM runtimes to build.
default_llvm_runtimes() {
	echo "compiler-rt;libcxx;libcxxabi;libunwind;openmp"
}

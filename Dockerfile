FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    clang \
    cmake \
    curl \
    file \
    git \
    jq \
    lld \
    llvm \
    ninja-build \
    pixz \
    python3 \
    tar \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

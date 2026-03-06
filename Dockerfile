FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /workspace

RUN apt-get update && apt-get install -y \
    ca-certificates \
    clang \
    cmake \
    curl \
    git \
    gh \
    jq \
    lld \
    llvm \
    ninja-build \
    pixz \
    zlib1g-dev \
    xz-utils \
 && rm -rf /var/lib/apt/lists/*

COPY . /workspace

RUN chmod +x /workspace/ci-local.sh

CMD ["/workspace/ci-local.sh"]

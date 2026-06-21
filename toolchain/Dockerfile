# reTasker build toolchain — reMarkable Paper Pro (ferrari / aarch64 / Codex scarthgap)
#
# Bakes the official reMarkable "ferrari" Yocto SDK (aarch64 cross-gcc + sysroot +
# Qt6 rcc) plus a clone of XOVI (for util/xovigen.py and headers). Build commands
# source the SDK's environment-setup script, which exports CC/CXX/CFLAGS/
# SDKTARGETSYSROOT/OECORE_TARGET_ARCH — exactly what the upstream Makefiles expect.
#
# The SDK installer is an x86_64 self-extracting script, so this image is amd64
# (runs under qemu on Apple Silicon via colima — fine for cross-compiling).
FROM --platform=linux/amd64 debian:bookworm-slim

ARG SDK_URL=https://storage.googleapis.com/remarkable-codex-toolchain/3.14.3.0/meta-toolchain-remarkable-4.0.813-ferrari-public-x86_64-toolchain.sh
ARG SDK_SHA256=29e2cce4280dbde182937c9614681a59a14aca8a18e06957bf66f8aeb0f3b968

RUN apt-get update && apt-get install -y --no-install-recommends \
        wget ca-certificates python3 git make file xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Download, verify, and install the SDK non-interactively to /opt/rm-sdk.
RUN wget -q -O /tmp/sdk.sh "$SDK_URL" \
    && echo "${SDK_SHA256}  /tmp/sdk.sh" | sha256sum -c - \
    && chmod +x /tmp/sdk.sh \
    && /tmp/sdk.sh -y -d /opt/rm-sdk \
    && rm /tmp/sdk.sh

# XOVI repo provides util/xovigen.py (turns .xovi descriptors into xovi.c/.h).
RUN git clone --depth 1 https://github.com/asivery/xovi /opt/xovi
ENV XOVI_REPO=/opt/xovi
ENV TMP=/tmp/rmbuild

# Resolve the SDK env-setup script path at build time and expose it.
RUN echo "export RM_ENV=$(ls /opt/rm-sdk/environment-setup-* | head -1)" > /etc/profile.d/rm-sdk.sh \
    && cat /etc/profile.d/rm-sdk.sh

WORKDIR /work

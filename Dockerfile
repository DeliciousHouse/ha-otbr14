###############################################################################
#  OpenThread BR (Thread 1.4 build) – Home-Assistant add-on Dockerfile
#  Works with build.yaml that sets:
#      build_from:
#        aarch64: ghcr.io/home-assistant/aarch64-base-debian:bookworm
#        amd64:   ghcr.io/home-assistant/amd64-base-debian:bookworm
#      args:
#        OTBR_VERSION: "<commit SHA or tag v1.4.x>"
#        UNIVERSAL_SILABS_FLASHER: "0.0.28"
###############################################################################

# Supervisor injects the correct base image for the architecture
ARG BUILD_FROM
FROM ${BUILD_FROM}

#-- build-time variables (passed from build.yaml) -----------------------------
ARG OTBR_VERSION
ARG UNIVERSAL_SILABS_FLASHER

# Use bash + pipefail for every RUN
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Feature flags exposed at runtime
ENV BORDER_ROUTING=1 \
    BACKBONE_ROUTER=1 \
    PLATFORM=debian \
    RELEASE=1 \
    WEB_GUI=1 \
    REST_API=1 \
    DHCPV6_PD_REF=0 \
    DOCKER=1

###############################################################################
# ----- build dependencies & helper files ------------------------------------
###############################################################################
COPY 0001-channel-monitor-disable-by-default.patch /usr/src/
COPY openthread-core-ha-config-posix.h           /usr/src/

# Packages required **before** script/bootstrap runs
RUN set -eux && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        # tools we call BEFORE bootstrap
        git patch diffutils \
        # OTBR build deps (same list as upstream script/bootstrap)
        build-essential ninja-build cmake wget ca-certificates \
        libreadline-dev libncurses-dev libcpputest-dev libdbus-1-dev \
        libavahi-common-dev libavahi-client-dev libboost-dev \
        libboost-filesystem-dev libboost-system-dev libnetfilter-queue-dev \
        # runtime helpers
        iproute2 python3 python3-pip lsb-release netcat-openbsd socat sudo \
        nodejs npm && \
\
###############################################################################
# ----- clone & build OTBR ----------------------------------------------------
###############################################################################
    git clone --depth 1 -b main https://github.com/openthread/ot-br-posix.git && \
    cd ot-br-posix && \
    git fetch origin "${OTBR_VERSION}" && \
    git checkout "${OTBR_VERSION}" && \
    git submodule update --init && \
    ./script/bootstrap && \
\
    # apply HA patch & custom proj-config BEFORE we run cmake
    cd third_party/openthread/repo && \
    patch -p1 < /usr/src/0001-channel-monitor-disable-by-default.patch && \
    cp /usr/src/openthread-core-ha-config-posix.h . && \
    cd ../../.. && \
\
    # make “openthread” routing table entry (matches upstream install script)
    echo "88 openthread" >> /etc/iproute2/rt_tables && \
\
    ./script/cmake-build \
        -DBUILD_TESTING=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DOTBR_FEATURE_FLAGS=ON \
        -DOTBR_DNSSD_DISCOVERY_PROXY=ON \
        -DOTBR_SRP_ADVERTISING_PROXY=ON \
        -DOTBR_MDNS=mDNSResponder \
        -DOTBR_DBUS=OFF \
        -DOT_POSIX_RCP_BUS_UART=ON \
        -DOT_LINK_RAW=1 \
        -DOTBR_VENDOR_NAME="Home Assistant" \
        -DOTBR_PRODUCT_NAME="OpenThread Border Router" \
        -DOTBR_WEB=ON \
        -DOTBR_BORDER_ROUTING=ON \
        -DOTBR_REST=ON \
        -DOTBR_BACKBONE_ROUTER=ON \
        -DOTBR_TREL=ON \
        -DOTBR_NAT64=ON \
        -DOT_POSIX_NAT64_CIDR="192.168.255.0/24" \
        -DOTBR_DNS_UPSTREAM_QUERY=ON \
        -DOT_CHANNEL_MONITOR=ON \
        -DOT_COAP=OFF -DOT_COAPS=OFF -DOT_DNS_CLIENT_OVER_TCP=OFF \
        -DOT_THREAD_VERSION=1.3 \
        -DOT_PROJECT_CONFIG="../openthread-core-ha-config-posix.h" \
        -DOT_RCP_RESTORATION_MAX_COUNT=2 && \
    cd build/otbr && ninja && ninja install && \
\
###############################################################################
# ----- flash helper & clean-up ----------------------------------------------
###############################################################################
    pip install universal-silabs-flasher=="${UNIVERSAL_SILABS_FLASHER}" && \
\
    apt-get purge -y --auto-remove \
        git patch diffutils nodejs npm \
        build-essential ninja-build cmake wget ca-certificates \
        libreadline-dev libncurses-dev libcpputest-dev libdbus-1-dev \
        libavahi-common-dev libavahi-client-dev libboost-dev \
        libboost-filesystem-dev libboost-system-dev \
        libnetfilter-queue-dev && \
    rm -rf /var/lib/apt/lists/* /usr/src/*

###############################################################################
# ----- overlay & final tweaks -----------------------------------------------
###############################################################################
COPY rootfs /
ENV S6_STAGE2_HOOK=/etc/s6-overlay/scripts/enable-check.sh

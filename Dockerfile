# ---- build stage -------------------------------------------------
FROM ubuntu:24.04 AS build

ARG ZIG_VERSION=0.15.2
ARG LIBAVIF_VERSION=1.3.0
ARG LIBWEBP_VERSION=1.4.0
ARG LIBJPEG_TURBO_VERSION=3.1.3
ARG LIBSPNG_VERSION=0.7.4
ARG LIBAOM_VERSION=v3.13.1

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl cmake git wget ca-certificates xz-utils \
    pkg-config zlib1g-dev nasm libheif-dev\
 && rm -rf /var/lib/apt/lists/*

# Zig 
RUN curl https://ziglang.org/download/${ZIG_VERSION}/zig-$(uname -m)-linux-${ZIG_VERSION}.tar.xz -o zig-linux.tar.xz && \
    mkdir /opt/zig && \
    tar xf zig-linux.tar.xz -C /opt/zig --strip-components=1
ENV PATH="/opt/zig:${PATH}"

# Build dirs
WORKDIR /build
ENV BUILD_DIR=/build
ENV INSTALL_PREFIX=/build/install
ENV PKG_CONFIG_PATH=/build/install/lib/pkgconfig
ENV CFLAGS="-I/build/install/include"
ENV LDFLAGS="-L/build/install/lib"
RUN mkdir -p /build/install

# libjpeg-turbo
RUN wget -q https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_TURBO_VERSION}/libjpeg-turbo-${LIBJPEG_TURBO_VERSION}.tar.gz \
 && tar -xzf libjpeg-turbo-${LIBJPEG_TURBO_VERSION}.tar.gz \
 && cmake -S libjpeg-turbo-${LIBJPEG_TURBO_VERSION} -B jt \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_JPEG8=ON \
 && cmake --build jt -j$(nproc) && cmake --install jt

# libwebp
RUN wget -q https://github.com/webmproject/libwebp/archive/refs/tags/v${LIBWEBP_VERSION}.tar.gz -O libwebp.tgz \
 && tar -xzf libwebp.tgz \
 && cmake -S libwebp-${LIBWEBP_VERSION} -B webp \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
 && cmake --build webp -j$(nproc) && cmake --install webp

# libspng
RUN wget -q https://github.com/randy408/libspng/archive/refs/tags/v${LIBSPNG_VERSION}.tar.gz -O libspng.tgz \
 && tar -xzf libspng.tgz \
 && cmake -S libspng-${LIBSPNG_VERSION} -B spng \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DSPNG_STATIC=ON \
 && cmake --build spng -j$(nproc) && cmake --install spng \
 && if [ -f ${INSTALL_PREFIX}/lib/libspng_static.a ]; then mv ${INSTALL_PREFIX}/lib/libspng_static.a ${INSTALL_PREFIX}/lib/libspng.a; fi \
 && rm -f ${INSTALL_PREFIX}/lib/libspng.so*

# libavif
RUN wget -q https://github.com/AOMediaCodec/libavif/archive/refs/tags/v${LIBAVIF_VERSION}.tar.gz -O libavif.tgz \
 && tar -xzf libavif.tgz \
 && cmake -S libavif-${LIBAVIF_VERSION} -B avif \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DAVIF_CODEC_AOM=LOCAL -DAVIF_AOM_GIT_TAG=${LIBAOM_VERSION} \
    -DAVIF_LIBYUV=LOCAL \
    -DAVIF_CODEC_DAV1D=OFF -DAVIF_CODEC_RAV1E=OFF -DAVIF_CODEC_SVT=OFF \
    -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF -DAVIF_BUILD_EXAMPLES=OFF \
 && cmake --build avif -j$(nproc) && cmake --install avif

# oavif (static)
ADD . /build/oavif
RUN cd /build/oavif \
 && zig build --release=fast --search-prefix ${INSTALL_PREFIX}

# ---- final stage -------------------------------------------------
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /build/oavif/zig-out/bin/oavif /oavif
USER nonroot
ENTRYPOINT ["/oavif"]

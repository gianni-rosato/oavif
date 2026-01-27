# ---- build stage -------------------------------------------------
FROM ubuntu:24.04 AS build
ARG ZIG_VERSION=0.15.2
ARG LIBAVIF_VERSION=1.3.0
ARG LIBWEBP_VERSION=1.4.0
ARG LIBJPEG_TURBO_VERSION=3.1.3
ARG LIBSPNG_VERSION=0.7.4
ARG LIBAOM_VERSION=v3.13.1
ARG SVTAV1_VERSION=v3.1.2
ARG DAV1D_VERSION=1.5.0
ARG RAV1E_VERSION=0.8.1

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl cmake git wget ca-certificates xz-utils \
    pkg-config zlib1g-dev nasm libheif-dev libpng-dev meson \
    libstdc++6 libgav1-dev libgcc-s1 gcc-14-base \
    && rm -rf /var/lib/apt/lists/*

# Zig 
RUN curl https://ziglang.org/download/${ZIG_VERSION}/zig-$(uname -m)-linux-${ZIG_VERSION}.tar.xz -o zig-linux.tar.xz && \
    mkdir /opt/zig && \
    tar xf zig-linux.tar.xz -C /opt/zig --strip-components=1
ENV PATH="/opt/zig:${PATH}"

WORKDIR /build
ENV INSTALL_PREFIX=/build/install
ENV PKG_CONFIG_PATH=${INSTALL_PREFIX}/lib/pkgconfig:${INSTALL_PREFIX}/lib/x86_64-linux-gnu/pkgconfig
ENV CFLAGS="-I/build/install/include"
ENV LDFLAGS="-L/build/install/lib -L/usr/lib/x86_64-linux-gnu"
RUN mkdir -p ${INSTALL_PREFIX}

# libjpeg-turbo
RUN wget -q https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_TURBO_VERSION}/libjpeg-turbo-${LIBJPEG_TURBO_VERSION}.tar.gz \
 && tar -xzf libjpeg-turbo-${LIBJPEG_TURBO_VERSION}.tar.gz \
 && cmake -S libjpeg-turbo-${LIBJPEG_TURBO_VERSION} -B jt -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
 && cmake --build jt -j$(nproc) && cmake --install jt

# libspng
RUN wget -q https://github.com/randy408/libspng/archive/refs/tags/v${LIBSPNG_VERSION}.tar.gz -O libspng.tgz \
 && tar -xzf libspng.tgz \
 && cmake -S libspng-${LIBSPNG_VERSION} -B spng -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DSPNG_STATIC=ON \
 && cmake --build spng -j$(nproc) && cmake --install spng \
 && ln -s ${INSTALL_PREFIX}/lib/libspng_static.a ${INSTALL_PREFIX}/lib/libspng.a

# libwebp
RUN wget -q https://github.com/webmproject/libwebp/archive/refs/tags/v${LIBWEBP_VERSION}.tar.gz -O libwebp.tgz \
 && tar -xzf libwebp.tgz \
 && cmake -S libwebp-${LIBWEBP_VERSION} -B webp -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} -DBUILD_SHARED_LIBS=OFF \
 && cmake --build webp -j$(nproc) && cmake --install webp

# dav1d
RUN wget -q https://code.videolan.org/videolan/dav1d/-/archive/${DAV1D_VERSION}/dav1d-${DAV1D_VERSION}.tar.gz -O dav1d.tgz \
 && tar -xzf dav1d.tgz \
 && meson setup dav1d-${DAV1D_VERSION}/build dav1d-${DAV1D_VERSION} --prefix=${INSTALL_PREFIX} --buildtype=release --default-library=static \
 && meson compile -C dav1d-${DAV1D_VERSION}/build && meson install -C dav1d-${DAV1D_VERSION}/build

# libavif
RUN wget -q https://github.com/AOMediaCodec/libavif/archive/refs/tags/v${LIBAVIF_VERSION}.tar.gz -O libavif.tgz \
 && tar -xzf libavif.tgz \
 && cmake -S libavif-${LIBAVIF_VERSION} -B avif \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DAVIF_CODEC_AOM=LOCAL -DAVIF_AOM_GIT_TAG=${LIBAOM_VERSION} \
    -DAVIF_CODEC_DAV1D=LOCAL \
    -DAVIF_CODEC_RAV1E=OFF \
    -DAVIF_CODEC_SVT=OFF \
    -DAVIF_LIBYUV=LOCAL \
    -DAVIF_BUILD_APPS=ON \
 && cmake --build avif -j$(nproc) && cmake --install avif

# oavif
ADD . /build/oavif
WORKDIR /build/oavif
RUN zig build --release=fast --search-prefix ${INSTALL_PREFIX}

# ---- final stage -------------------------------------------------
FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /build/oavif/zig-out/bin/oavif /oavif
COPY --from=build /build/install/ /build
COPY --from=build /lib/x86_64-linux-gnu/libgcc_s.so.1 /lib/x86_64-linux-gnu/
COPY --from=build /usr/lib/x86_64-linux-gnu/libstdc++.so.6 /usr/lib/x86_64-linux-gnu/
USER nonroot
ENTRYPOINT ["/oavif"]
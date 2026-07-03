# libd2 — native Zig DRLG map-render HTTP server (DeadlyBossMods-shaped JSON).
# Self-contained: the game blobs are @embedFile'd into the binary. Alpine build
# (native musl + system libz) → tiny alpine runtime. Stateless.
FROM alpine:3.20 AS build
ARG ZIG_VERSION=0.16.0
RUN apk add --no-cache curl xz tar zlib-dev zlib-static \
 && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
 && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
 && ln -s /opt/zig/zig /usr/local/bin/zig && zig version
WORKDIR /src
# Whole monorepo: drlg-server path-deps drlg -> formats/fog; blobs live in packages/drlg.
COPY packages ./packages
WORKDIR /src/packages/drlg-server
RUN zig build -Doptimize=ReleaseFast

FROM alpine:3.20
RUN apk add --no-cache zlib libgcc
COPY --from=build /src/packages/drlg-server/zig-out/bin/drlg-server /usr/local/bin/drlg-server
EXPOSE 8080
ENTRYPOINT ["drlg-server", "--port", "8080"]

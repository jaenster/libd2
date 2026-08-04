# Build context is the REPOSITORY ROOT, not this directory — the wasm is compiled from
# packages/wasm (and every package it links), so the whole monorepo has to be visible:
#
#   docker build -f apps/automap/Dockerfile -t automap .

ARG ZIG_VERSION=0.16.0

FROM debian:bookworm-slim AS wasm
ARG ZIG_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
  | tar -xJ -C /opt && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
WORKDIR /src
COPY packages ./packages
RUN cd packages/wasm && zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall -Dcapi=drlg,pf

FROM node:22-slim AS web
RUN corepack enable
WORKDIR /app
COPY apps/automap/package.json apps/automap/pnpm-lock.yaml apps/automap/pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY apps/automap/ ./
COPY --from=wasm /src/packages/wasm/zig-out/bin/libd2.wasm ./public/libd2.wasm
# The wasm is already built and copied in; skip the prebuild hook's Zig invocation.
RUN pnpm exec tsc --noEmit && pnpm exec vite build

FROM nginx:1.27-alpine
COPY apps/automap/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=web /app/dist /usr/share/nginx/html
EXPOSE 80

FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates git build-essential libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit c0624b274 (built from source). No release
# tag carries the modern stdlib this framework needs: the pooled Go-style `db.pg`
# (vlang/v#27265), the `fasthttp` `-prealloc` request-arena (frees per request, no
# GC), and the single-element-array-push codegen fix (vlang/v#27470, which is why
# 0.5.1 was previously pinned). `make` bootstraps via the matching vc; if a much
# later rebuild ever fails to bootstrap, pin vlang/vc to the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout c0624b274 && \
    make && ln -s /opt/v/v /usr/local/bin/v

WORKDIR /app
COPY . .
# -prealloc (NOT -gc none): fasthttp resets a per-request memory arena, so memory is
# reclaimed after each request with no garbage collector.
RUN v -prod -prealloc . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
CMD ["/server"]

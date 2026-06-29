FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git libpq-dev liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 02015a7c (built from source). Moved off
# the 0.5.1 tag: the codegen regression that forced the pin (single-element array
# push 4-7x slower, vlang/v#27468) is fixed (vlang/v#27470), and the vanilla library
# now uses `ArrayFlags.managed` (the buf_view non-marking window) which only exists
# on post-0.5.1 V. `make` bootstraps via the matching vc; if a much later rebuild
# ever fails to bootstrap, pin vlang/vc to the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout 02015a7ce111e4d0cfd5b5d78711ad0db7586936 && \
    make && ln -s /opt/v/v /usr/local/bin/v

# Install the vanilla HTTP server as the `vanilla` module (import vanilla.http_server),
# pinned to a specific commit: reproducible, and with NO per-build network call to
# detect changes. The previous approach `ADD`ed the GitHub API main-ref URL to cache-bust
# whenever main moved, but that hit api.github.com on every build and a transient 504
# (or rate-limit) failed the whole build (MDA2AV/HttpArena#895). To pick up upstream
# library fixes, bump this commit.
#
# vanilla bumped to main + enghitalo/vanilla#80 (static_assets `url_prefix`): this
# entry now serves /static/* through the audited static_assets module (precompressed
# .br/.gz negotiation per Accept-Encoding + ETag/Vary + sendfile) instead of a second,
# hand-rolled identity-only map that ignored Accept-Encoding. The bump also catches up
# to current vanilla main (#75 core.queue_buf, #79 kTLS record offload) — both inert
# in this image (built without -d vanilla_tls; queue_buf is unused by the epoll entry).
RUN git clone https://github.com/enghitalo/vanilla /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla checkout f59a534045e5731a6c03f16ea23f19cbfe2e7334

WORKDIR /app
COPY . .
RUN v -prod -gc none . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 liburing2 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
CMD ["/server"]

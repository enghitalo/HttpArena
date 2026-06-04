FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git libpq-dev liburing-dev && \
    rm -rf /var/lib/apt/lists/*

# Build V from the master branch (reports `V 0.5.1`). Pinning a tag with
# `git checkout <tag> && make` is unreliable because make pulls the latest vc.
RUN git clone --depth 1 https://github.com/vlang/v /opt/vlang && \
    cd /opt/vlang && make && ln -s /opt/vlang/v /usr/local/bin/v

# Install the vanilla HTTP server as the `vanilla` module (import vanilla.http_server).
RUN mkdir -p /root/.vmodules && \
    git clone --depth 1 https://github.com/enghitalo/vanilla /root/.vmodules/vanilla

WORKDIR /app
COPY . .
RUN v -prod . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 liburing2 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server

EXPOSE 8080
CMD ["/server"]

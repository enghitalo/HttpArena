FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /app
COPY frameworks/aspnet-minimal/ .
COPY data/static/ wwwroot/static/
RUN dotnet publish -c Release -o out

# dotnet-trace needs the SDK to install — build it here and copy the
# self-contained tool dir into the runtime stage.
RUN dotnet tool install --tool-path /opt/dotnet-tools dotnet-trace

FROM mcr.microsoft.com/dotnet/aspnet:10.0


ADD https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb /packages-microsoft-prod.deb

RUN dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends libmsquic \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Diagnostics — dotnet-trace for CPU sampling traces, DOTNET_PerfMapEnabled
# so any external profiler (perf, perfcollect, eBPF) can resolve managed
# method names. Both are zero-cost at idle; the trace tool only consumes
# CPU when actually attached.
COPY --from=build /opt/dotnet-tools /opt/dotnet-tools
ENV PATH="/opt/dotnet-tools:${PATH}"
ENV DOTNET_PerfMapEnabled=1
ENV DOTNET_EnableEventPipe=1

WORKDIR /app
COPY --from=build /app/out .
EXPOSE 8080 8081 8082 8443/tcp 8443/udp

ENTRYPOINT ["dotnet", "aspnet-minimal.dll"]
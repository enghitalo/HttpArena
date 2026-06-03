# ---- Build: clone the CodeGreen port and build a fat jar via a Gradle composite build ----
FROM eclipse-temurin:21-jdk AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app

COPY . .

# CodeGreen (the Kotlin GenHTTP port) is consumed as a composite build, wired in
# settings.gradle.kts via includeBuild("codegreen"). Pin to the port branch.
RUN git clone --depth 1 --branch port https://github.com/dotnet-web-stack/CodeGreen.git codegreen

RUN chmod +x ./gradlew && ./gradlew shadowJar --no-daemon

# ---- Runtime ----
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/build/libs/fishcake.jar .
EXPOSE 8080
ENTRYPOINT ["java", \
  "-server", \
  "-XX:+UseG1GC", \
  "-XX:+UseNUMA", \
  "-XX:+AlwaysPreTouch", \
  "-XX:-OmitStackTraceInFastThrow", \
  "-Dio.netty.buffer.checkBounds=false", \
  "-Dio.netty.buffer.checkAccessible=false", \
  "-Dio.netty.leakDetection.level=disabled", \
  "-Dio.netty.recycler.maxCapacityPerThread=4096", \
  "-Dio.netty.eventLoopThreads=0", \
  "-jar", "fishcake.jar"]

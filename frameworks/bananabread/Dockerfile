FROM oven/bun:1-alpine
RUN apk add --no-cache git
WORKDIR /app

# App deps (reflect-metadata powers the decorator-based webservice routing).
COPY package.json ./
RUN bun install

COPY tsconfig.json ./
COPY src ./src

# Seagreen (the TypeScript GenHTTP port) is consumed by relative import from ./seagreen.
# Cloned at build time from its public repo; bare imports (reflect-metadata) resolve from /app.
RUN git clone --depth 1 https://github.com/dotnet-web-stack/Seagreen.git seagreen

EXPOSE 8080
# Bun runs the TypeScript directly (no build step); main.ts forks one worker per core.
ENTRYPOINT ["bun", "run", "src/main.ts"]

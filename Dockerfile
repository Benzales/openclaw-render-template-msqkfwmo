FROM node:22.22.3-slim

RUN apt-get update && apt-get install -y git curl procps python3 make g++ cron tini && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --prefer-online && npm cache clean --force

ENV PATH="/app/node_modules/.bin:$PATH"

# gbrain: Ben's knowledge brain CLI. Needs bun; copy the binary from the official
# image rather than running bun's installer, which requires unzip (absent in slim).
COPY --from=oven/bun:1 /usr/local/bin/bun /usr/local/bin/bun
RUN bun install -g github:garrytan/gbrain
ENV PATH="/root/.bun/bin:$PATH"
RUN gbrain --version
ENV ALPHACLAW_ROOT_DIR=/data

RUN mkdir -p /data

EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["alphaclaw", "start"]

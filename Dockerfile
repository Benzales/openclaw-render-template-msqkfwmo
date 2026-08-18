FROM node:22.22.3-slim

RUN apt-get update && apt-get install -y git curl procps python3 make g++ cron tini && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --prefer-online && npm cache clean --force

ENV PATH="/app/node_modules/.bin:$PATH"

# gbrain: Ben's knowledge brain CLI. Needs bun; copy the binary from the official
# image rather than running bun's installer, which requires unzip (absent in slim).
COPY --from=oven/bun:1 /usr/local/bin/bun /usr/local/bin/bun
# PINNED, deliberately. An unpinned install means every rebuild silently lands
# on a different gbrain, and the schema is SHARED with the Mac via Supabase:
# whichever machine runs the newer binary drags migrations forward for both.
# Bump this only in step with the Mac (see meta/OPERATIONS.md).
ARG GBRAIN_VERSION=v0.46.19.0
RUN bun install -g "github:garrytan/gbrain#${GBRAIN_VERSION}"
ENV PATH="/root/.bun/bin:$PATH"
RUN gbrain --version
ENV ALPHACLAW_ROOT_DIR=/data
# gbrain resolves its config dir as $GBRAIN_HOME/.gbrain. Left unset it lands in
# /root/.gbrain, which is container-local and wiped on every redeploy, taking the
# config, the git credential store and the locks with it. /data is the disk.
ENV GBRAIN_HOME=/data

RUN mkdir -p /data

EXPOSE 3000

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# -g so tini signals the whole process group; start.sh runs two children.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/start.sh"]

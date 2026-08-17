#!/usr/bin/env bash
# Boot the box as the gbrain HOST plus the Loom agent.
#
# Two long-lived children under one container. `wait -n` is load-bearing: if
# either child dies the container exits so Render restarts it. Without it a
# dead gbrain serve would sit behind a healthy /health on 3000 indefinitely.
set -uo pipefail

BRAIN_DIR="${BRAIN_REPO_PATH:-/data/brain}"
BRAIN_REPO="${BRAIN_REPO:-Benzales/brain}"
BRAIN_BRANCH="${BRAIN_BRANCH:-main}"
GBRAIN_PORT="${GBRAIN_SERVE_PORT:-3131}"

log() { echo "$(date -u +%FT%TZ) [start] $*"; }

# Secrets live in /data/.env, managed through the AlphaClaw Envars UI. That file
# is read by the AlphaClaw server process, which starts AFTER us, so nothing here
# would see GITHUB_TOKEN or GBRAIN_DATABASE_URL without this step. Import only the
# keys we need, and never clobber a value Render already set (PORT in particular).
ENV_FILE="${ENV_FILE:-/data/.env}"
if [ -r "$ENV_FILE" ]; then
  for k in GITHUB_TOKEN GBRAIN_DATABASE_URL OPENAI_API_KEY ANTHROPIC_API_KEY; do
    if [ -z "${!k:-}" ]; then
      v=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${k}=" "$ENV_FILE" | tail -n1 | sed -e "s/^[^=]*=//")
      v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
      [ -n "$v" ] && export "$k=$v" && log "imported $k from $ENV_FILE"
    fi
  done
else
  log "WARN $ENV_FILE not readable; relying on Render env vars alone"
fi

# One token covers Benzales/agent and Benzales/brain (Contents: read+write).
GIT_TOKEN="${BRAIN_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"

# Credentials via a store file, never in the remote URL: a tokenised remote
# leaks into `git remote -v`, into logs, and into every push error message.
if [ -n "$GIT_TOKEN" ]; then
  umask 077
  printf 'https://x-access-token:%s@github.com\n' "$GIT_TOKEN" > /data/.git-credentials
  git config --global credential.helper 'store --file /data/.git-credentials'
else
  log "WARN no GitHub token; a private brain repo will not clone"
fi
git config --global user.name  "${GIT_AUTHOR_NAME:-Loom}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-loom@users.noreply.github.com}"
git config --global --add safe.directory "$BRAIN_DIR"

# Clone if absent, pull if present. Never fatal: a stale checkout beats no box.
if [ -d "$BRAIN_DIR/.git" ]; then
  log "pulling $BRAIN_DIR"
  git -C "$BRAIN_DIR" fetch --prune origin "$BRAIN_BRANCH" \
    && git -C "$BRAIN_DIR" pull --ff-only origin "$BRAIN_BRANCH" \
    || log "WARN pull failed; continuing on the existing checkout (now stale)"
else
  log "cloning $BRAIN_REPO -> $BRAIN_DIR"
  git clone --branch "$BRAIN_BRANCH" "https://github.com/${BRAIN_REPO}.git" "$BRAIN_DIR" \
    || log "ERROR clone failed; gbrain serve starts without a checkout"
fi

declare -a PIDS=()
term() { log "SIGTERM; stopping children"; kill -TERM "${PIDS[@]}" 2>/dev/null; }
trap term TERM INT

# cd first: .gbrain-source is resolved from CWD, and it is what pins the server
# to the `brain` source instead of the dead `default` one.
cd "$BRAIN_DIR" 2>/dev/null || { log "WARN no $BRAIN_DIR; serving from /app"; cd /app; }

gbrain serve --http --port "$GBRAIN_PORT" --bind 127.0.0.1 & PIDS+=($!)
log "gbrain serve --http on 127.0.0.1:$GBRAIN_PORT (pid ${PIDS[-1]})"

alphaclaw start & PIDS+=($!)
log "alphaclaw start (pid ${PIDS[-1]})"

wait -n
code=$?
log "a child exited ($code); shutting the container down so Render restarts it"
kill -TERM "${PIDS[@]}" 2>/dev/null
wait
exit "$code"

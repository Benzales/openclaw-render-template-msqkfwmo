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

# The agent repo (skills, identity) is /data/.openclaw, a git checkout of
# Benzales/agent that alphaclaw auto-PUSHES but never pulls. It sat 6 commits
# behind for days, leaving Loom with 1 skill out of 69, and nothing surfaced it.
# ff-only and clean-tree-only, so this can never fight the auto-push or eat work.
OPENCLAW_DIR="${OPENCLAW_DIR:-/data/.openclaw}"
if [ -d "$OPENCLAW_DIR/.git" ]; then
  if [ -z "$(git -C "$OPENCLAW_DIR" status --porcelain)" ]; then
    git -C "$OPENCLAW_DIR" fetch -q origin main \
      && git -C "$OPENCLAW_DIR" pull --ff-only origin main \
      && log "agent repo up to date ($(ls "$OPENCLAW_DIR/skills" 2>/dev/null | wc -l | tr -d ' ') skills)" \
      || log "WARN agent-repo pull failed; skills may be stale"
  else
    log "WARN $OPENCLAW_DIR is dirty; skipping pull so nothing local is lost"
  fi
fi

# Loom staying up matters more than the brain server does. An earlier version ran
# both children under `wait -n`, which meant a gbrain serve that could not start
# would exit the container, and Render would restart it into the same failure:
# a crash loop that takes the always-on agent offline over a brain-side problem.
# So serve gets supervised and retried forever, and only alphaclaw's death ends
# the container. A permanently broken serve is loud in the logs, not fatal.
serve_loop() {
  n=0
  while :; do
    gbrain serve --http --port "$GBRAIN_PORT" --bind 127.0.0.1
    n=$((n + 1))
    log "WARN gbrain serve exited (restart #$n); retrying in 15s"
    sleep 15
  done
}

# cd first: .gbrain-source is resolved from CWD, and it is what pins the server
# to the `brain` source instead of the dead `default` one.
cd "$BRAIN_DIR" 2>/dev/null || { log "WARN no $BRAIN_DIR; serving from /app"; cd /app; }

serve_loop & SERVE_PID=$!
log "gbrain serve supervised on 127.0.0.1:$GBRAIN_PORT (pid $SERVE_PID)"

alphaclaw start & AC_PID=$!
log "alphaclaw start (pid $AC_PID)"

term() { log "SIGTERM; stopping children"; kill -TERM "$SERVE_PID" "$AC_PID" 2>/dev/null; }
trap term TERM INT

wait "$AC_PID"
code=$?
log "alphaclaw exited ($code); shutting down so Render restarts the service"
kill -TERM "$SERVE_PID" 2>/dev/null
exit "$code"

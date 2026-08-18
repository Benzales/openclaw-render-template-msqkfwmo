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
  # --untracked-files=no is load-bearing. Loom writes memory files under
  # workspace/, which .gitignore whitelists, so a bare --porcelain reports the
  # tree dirty almost whenever Loom has been working and this pull silently
  # skips. That is the mechanism behind "Loom had 1 skill out of 69": the pull
  # existed, gated on a condition Loom's own writes keep breaking. Only TRACKED
  # modifications should block it; ff-only refuses on its own if an incoming
  # commit would clobber an untracked path, so nothing local is at risk.
  if [ -z "$(git -C "$OPENCLAW_DIR" status --porcelain --untracked-files=no)" ]; then
    git -C "$OPENCLAW_DIR" fetch -q origin main \
      && git -C "$OPENCLAW_DIR" pull --ff-only origin main \
      && log "agent repo up to date ($(ls "$OPENCLAW_DIR/skills" 2>/dev/null | wc -l | tr -d ' ') skills)" \
      || log "WARN agent-repo pull failed; skills may be stale"
  else
    log "WARN $OPENCLAW_DIR has uncommitted TRACKED changes; skipping pull so nothing local is lost"
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

# The minion queue had no worker anywhere, on any machine. Jobs accumulated
# (`gbrain sync` enqueues facts-absorb on every reconcile pass) and nothing ever
# claimed them, so the backlog grew monotonically and one job sat leased-but-dead
# for 15h because no worker was alive to reap its expired lease either.
#
# `jobs supervisor` rather than `jobs work`: the supervisor IS the auto-restart
# wrapper around the worker, and it reaps stale PID locks on start, which matters
# because the pid file lands on the persistent disk and survives a redeploy.
# Foreground (no --detach) so this shell owns it, matching serve_loop.
#
# --concurrency 1 deliberately: 4GB is shared with Loom and gbrain serve. Raise it
# only after watching a full drain. Shell jobs stay OFF (the default); that flag
# is the remote-code-execution surface.
WORKER_CONCURRENCY="${WORKER_CONCURRENCY:-1}"
worker_loop() {
  n=0
  while :; do
    gbrain jobs supervisor start --queue default --concurrency "$WORKER_CONCURRENCY"
    n=$((n + 1))
    log "WARN jobs supervisor exited (restart #$n); retrying in 30s"
    sleep 30
  done
}

# cd first: .gbrain-source is resolved from CWD, and it is what pins the server
# to the `brain` source instead of the dead `default` one.
cd "$BRAIN_DIR" 2>/dev/null || { log "WARN no $BRAIN_DIR; serving from /app"; cd /app; }

# The host is the only indexer now, so Ben's pushes from the Mac have to reach it
# somehow. gbrain's own 30-minute pull cron deliberately skips containers, and the
# `gbrain remote ping` doorbell needs the server reachable from outside, which it
# is not (loopback only, by design). So reconcile on a timer: pull, then sync.
# --ff-only, and every failure is non-fatal, so this can never fight the
# write-through push or wedge the box.
RECONCILE_SECS="${RECONCILE_SECS:-900}"
reconcile_loop() {
  while :; do
    sleep "$RECONCILE_SECS"
    if [ -n "$(git -C "$BRAIN_DIR" status --porcelain)" ]; then
      log "reconcile: working tree dirty, skipping this pass"
      continue
    fi
    if git -C "$BRAIN_DIR" pull --ff-only origin "$BRAIN_BRANCH" >/dev/null 2>&1; then
      ( cd "$BRAIN_DIR" && gbrain sync --source brain --repo "$BRAIN_DIR" --workers 2 >/dev/null 2>&1 ) \
        && log "reconcile: pulled and re-indexed" \
        || log "WARN reconcile: sync failed"
    else
      log "WARN reconcile: pull failed (diverged or offline); index may be stale"
    fi
  done
}

serve_loop & SERVE_PID=$!
log "gbrain serve supervised on 127.0.0.1:$GBRAIN_PORT (pid $SERVE_PID)"

reconcile_loop & RECONCILE_PID=$!
log "reconcile loop every ${RECONCILE_SECS}s (pid $RECONCILE_PID)"

worker_loop & WORKER_PID=$!
log "jobs supervisor supervised, queue=default concurrency=$WORKER_CONCURRENCY (pid $WORKER_PID)"

alphaclaw start & AC_PID=$!
log "alphaclaw start (pid $AC_PID)"

term() { log "SIGTERM; stopping children"; kill -TERM "$SERVE_PID" "$RECONCILE_PID" "$WORKER_PID" "$AC_PID" 2>/dev/null; }
trap term TERM INT

wait "$AC_PID"
code=$?
log "alphaclaw exited ($code); shutting down so Render restarts the service"
kill -TERM "$SERVE_PID" "$RECONCILE_PID" "$WORKER_PID" 2>/dev/null
exit "$code"

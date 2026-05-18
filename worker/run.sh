#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p logs

lock_dir="logs/worker.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  if [ -f logs/worker.pid ]; then
    existing_pid="$(cat logs/worker.pid 2>/dev/null || true)"
    if [ -n "$existing_pid" ] && ps -p "$existing_pid" >/dev/null 2>&1; then
      echo "PodcastWorker already running with wrapper PID $existing_pid"
      exit 0
    fi
  fi
  echo "Removing stale worker lock"
  rm -rf "$lock_dir"
  mkdir "$lock_dir"
fi
trap 'rm -rf "$lock_dir"' EXIT INT TERM

echo $$ > logs/worker.pid

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${PODCAST_BACKEND_URL:=https://podcasts.hannesnagel.com}"
: "${PODCAST_WHISPER_COMMAND:=mlx_whisper}"
: "${PODCAST_WHISPER_MODEL:=mlx-community/whisper-large-v3-turbo}"
: "${PODCAST_WORKER_IDLE_SECONDS:=60}"
: "${PODCAST_CHAPTER_PROVIDER:=openrouter}"
: "${PODCAST_OPENROUTER_MODEL:=tencent/hy3-preview}"

export PODCAST_BACKEND_URL
export PODCAST_WHISPER_COMMAND
export PODCAST_WHISPER_MODEL
export PODCAST_WORKER_IDLE_SECONDS
export PODCAST_CHAPTER_PROVIDER
export PODCAST_OPENROUTER_MODEL
export PODCAST_OPENROUTER_API_KEY="${PODCAST_OPENROUTER_API_KEY:-}"

swift run -c release PodcastWorker

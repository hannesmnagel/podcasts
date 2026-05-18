#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

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

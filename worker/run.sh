#!/bin/bash
set -e

PODCAST_BACKEND_URL="https://podcasts.hannesnagel.com" \
PODCAST_WHISPER_COMMAND="mlx_whisper" \
PODCAST_WHISPER_MODEL="mlx-community/whisper-large-v3-turbo" \
PODCAST_WORKER_IDLE_SECONDS="60" \
swift run -c release PodcastWorker

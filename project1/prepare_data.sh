#!/usr/bin/env bash
# prepare_data.sh - скачивает каталог Spotify Tracks с Kaggle и строит listens.csv через PostgreSQL.
# Запуск: ./prepare_data.sh            (токен берется из переменных окружения или kaggle.json)
#
# ----- НАСТРОЙКА ТОКЕНА KAGGLE (один из способов) ----------------------------
# 1) переменные окружения (лучше всего, ничего не попадет в git):
#      export KAGGLE_USERNAME=ваш_логин  KAGGLE_KEY=ваш_ключ
#    либо, для нового формата токена:
#      export KAGGLE_API_TOKEN=ваш_токен
# 2) файл ~/.kaggle/kaggle.json  {"username":"...","key":"..."}
# 3) вписать значения прямо сюда (НЕ коммитьте файл с вписанным токеном!):
KAGGLE_USERNAME=${KAGGLE_USERNAME:-}
KAGGLE_KEY=${KAGGLE_KEY:-}
KAGGLE_API_TOKEN=${KAGGLE_API_TOKEN:-}
# -----------------------------------------------------------------------------
set -eu
cd "$(dirname "$0")"

SLUG="maharshipandya/-spotify-tracks-dataset"
URL="https://www.kaggle.com/api/v1/datasets/download/$SLUG"
DB=${PGDATABASE:-musicdb}          # подключение к PostgreSQL - стандартные PGHOST/PGUSER/PGPASSWORD

if [ ! -f dataset.csv ]; then
    if [ -z "$KAGGLE_USERNAME" ] && [ -z "$KAGGLE_API_TOKEN" ] && [ -r "$HOME/.kaggle/kaggle.json" ]; then
        KAGGLE_USERNAME=$(sed -n 's/.*"username"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.kaggle/kaggle.json")
        KAGGLE_KEY=$(sed -n 's/.*"key"[^"]*"\([^"]*\)".*/\1/p' "$HOME/.kaggle/kaggle.json")
    fi
    if [ -n "$KAGGLE_API_TOKEN" ]; then
        AUTH=(-H "Authorization: Bearer $KAGGLE_API_TOKEN")
    elif [ -n "$KAGGLE_USERNAME" ] && [ -n "$KAGGLE_KEY" ]; then
        AUTH=(-u "$KAGGLE_USERNAME:$KAGGLE_KEY")
    else
        echo "Нет токена Kaggle: см. комментарии в начале prepare_data.sh" >&2; exit 1
    fi
    echo "Скачиваю датасет с Kaggle..."
    curl -fL "${AUTH[@]}" -o /tmp/spotify_tracks.zip "$URL"
    unzip -o -j /tmp/spotify_tracks.zip dataset.csv -d .
    rm -f /tmp/spotify_tracks.zip
fi

echo "Генерирую listens.csv (PostgreSQL, база $DB)..."
psql -d "$DB" -v ON_ERROR_STOP=1 -q -f sql/generate.sql
wc -c listens.csv

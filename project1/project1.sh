#!/usr/bin/env bash
# project1.sh - метрики по логу прослушиваний музыкального сервиса.
# Использование: ./project1.sh listens.csv
# Только bash + стандартные утилиты (tail, awk, sort, uniq), без других языков.

set -eu
export LC_ALL=C   # одинаковая сортировка и точка в десятичных числах на любой машине

if [ $# -ne 1 ] || [ ! -r "$1" ]; then
    echo "Usage: $0 listens.csv" >&2
    exit 1
fi
DATA=$1

# Колонки: 1 event_id, 2 ts, 3 user_id, 4 country, 5 song_id, 6 song_name,
#          7 artist, 8 genre, 9 device, 10 listened_sec, 11 song_len_sec, 12 liked
# Первая строка - заголовок (tail -n +2). Строки не с 12 полями пропускаем (NF==12).

# --- Метрика 1: доля скипов (прослушивание короче 30 секунд) -----------------
tail -n +2 "$DATA" | awk -F',' '
    NF == 12 { total++; if ($10 + 0 < 30) skips++ }
    END {
        if (total == 0) { print "SKIP_RATE NA"; exit }
        printf "SKIP_RATE %.4f\n", skips / total
    }'

# --- Метрика 2: самый популярный жанр в каждой стране -----------------------
# awk -> пары "страна,жанр"; sort | uniq -c считает прослушивания каждой пары;
# последний awk выбирает для страны пару с максимумом (при ничьей - жанр по алфавиту).
tail -n +2 "$DATA" | awk -F',' 'NF == 12 { print $4 "," $8 }' \
    | sort | uniq -c \
    | awk '{
        n = $1; split($2, p, ",")
        c = p[1]; g = p[2]
        if (!(c in best) || n > best[c] || (n == best[c] && g < genre[c])) {
            best[c] = n; genre[c] = g
        }
    }
    END { for (c in best) print "TOPGENRE", c, genre[c], best[c] }' \
    | sort -k2,2

# --- Метрика 3: средняя доля дослушивания, mobile vs desktop по странам ------
# доля = listened_sec / song_len_sec (не больше 1); среднее по каждой паре страна+устройство
tail -n +2 "$DATA" | awk -F',' '
    NF == 12 && $11 > 0 && ($9 == "mobile" || $9 == "desktop") {
        r = $10 / $11; if (r > 1) r = 1
        sum[$4 SUBSEP $9] += r; cnt[$4 SUBSEP $9]++; seen[$4] = 1
    }
    END {
        for (c in seen) {
            m = ((c SUBSEP "mobile")  in cnt) ? sprintf("%.4f", sum[c SUBSEP "mobile"]  / cnt[c SUBSEP "mobile"])  : "NA"
            d = ((c SUBSEP "desktop") in cnt) ? sprintf("%.4f", sum[c SUBSEP "desktop"] / cnt[c SUBSEP "desktop"]) : "NA"
            print "COMPLETION", c, m, d
        }
    }' | sort -k2,2

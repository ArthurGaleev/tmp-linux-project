#!/usr/bin/env bash
# check.sh: сравнивает вывод project1.sh с результатом тех же метрик на SQL (sqlite3).
set -eu
DATA=${1:-listens.csv}
./project1.sh "$DATA" > /tmp/p1_awk.txt
sed "s#listens.csv#$DATA#" check.sql | sqlite3 -batch :memory: > /tmp/p1_sql.txt
if diff /tmp/p1_awk.txt /tmp/p1_sql.txt; then echo "CHECK OK: awk и SQL совпали"; else echo "CHECK FAILED"; exit 1; fi

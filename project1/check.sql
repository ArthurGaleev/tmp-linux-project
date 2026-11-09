-- check.sql: независимая проверка project1.sh через SQL (sqlite3).
-- Запуск: ./check.sh listens.csv (имя файла в .import подменяется через sed)
.mode csv
CREATE TABLE listens (event_id INTEGER, ts TEXT, user_id INTEGER, country TEXT, song_id INTEGER,
    song_name TEXT, artist TEXT, genre TEXT, device TEXT, listened_sec INTEGER, song_len_sec INTEGER, liked INTEGER);
.import --skip 1 listens.csv listens
.mode list
.separator " "

SELECT 'SKIP_RATE', printf('%.4f', AVG(listened_sec < 30)) FROM listens;

SELECT 'TOPGENRE', country, genre, cnt FROM (
    SELECT country, genre, COUNT(*) AS cnt,
           ROW_NUMBER() OVER (PARTITION BY country ORDER BY COUNT(*) DESC, genre) AS rn
    FROM listens GROUP BY country, genre)
WHERE rn = 1 ORDER BY country;

SELECT 'COMPLETION', country,
       COALESCE(printf('%.4f', AVG(CASE WHEN device = 'mobile'  THEN MIN(1.0, listened_sec * 1.0 / song_len_sec) END)), 'NA'),
       COALESCE(printf('%.4f', AVG(CASE WHEN device = 'desktop' THEN MIN(1.0, listened_sec * 1.0 / song_len_sec) END)), 'NA')
FROM listens WHERE song_len_sec > 0 AND device IN ('mobile', 'desktop')
GROUP BY country ORDER BY country;

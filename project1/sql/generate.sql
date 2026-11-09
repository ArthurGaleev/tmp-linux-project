-- ============================================================================
-- generate.sql - строит БД из каталога Spotify Tracks и генерирует журнал
-- прослушиваний listens.csv (PostgreSQL 13+).
-- Запуск (из папки project1, рядом лежит dataset.csv):
--   psql -v ON_ERROR_STOP=1 -f sql/generate.sql
-- Параметры модели (распределения) описаны в README_P1.md.
-- ============================================================================
\set ON_ERROR_STOP on
SELECT setseed(0.20261109);          -- воспроизводимость

\i sql/schema.sql

-- 1. Сырой каталог ---------------------------------------------------------
CREATE TEMP TABLE raw_tracks (
  idx int, track_id text, artists text, album_name text, track_name text, popularity int,
  duration_ms int, explicit boolean, danceability float8, energy float8, key int, loudness float8,
  mode int, speechiness float8, acousticness float8, instrumentalness float8, liveness float8,
  valence float8, tempo float8, time_signature int, track_genre text);
\copy raw_tracks FROM 'dataset.csv' CSV HEADER

-- 2. Справочники и параметры модели ----------------------------------------
INSERT INTO Countries (id, name) VALUES
  (0,'australia'),(1,'brazil'),(2,'france'),(3,'germany'),(4,'india'),(5,'japan'),(6,'sweden'),(7,'usa');

-- доля пользователей по странам (относительные веса)
CREATE TEMP TABLE country_cfg (country_id int, w float8);
INSERT INTO country_cfg VALUES (0,10),(1,14),(2,8),(3,12),(4,15),(5,12),(6,4),(7,25);

-- 16 жанров; is_global: «мировой» жанр (вес 1 везде), иначе локальный (вес 0.2, если не усилен)
CREATE TEMP TABLE gen_cfg (id int, name text, is_global boolean);
INSERT INTO gen_cfg VALUES
  (0,'pop',true),(1,'rock',true),(2,'hip-hop',true),(3,'edm',true),(4,'jazz',true),(5,'classical',true),
  (6,'country',true),(7,'heavy-metal',true),(8,'k-pop',false),(9,'j-pop',false),(10,'samba',false),
  (11,'indian',false),(12,'french',false),(13,'german',false),(14,'swedish',false),(15,'latin',false);
INSERT INTO Genres (id, name) SELECT id, name FROM gen_cfg;

-- усиленные пары страна-жанр
CREATE TEMP TABLE boost (country text, genre text, w float8);
INSERT INTO boost VALUES
  ('usa','country',4),('usa','hip-hop',3),('usa','pop',2),('usa','rock',2),
  ('germany','german',4),('germany','edm',3),('germany','rock',2),('germany','heavy-metal',2),
  ('brazil','samba',4),('brazil','latin',2),('brazil','hip-hop',2),('brazil','pop',2),
  ('japan','j-pop',5),('japan','k-pop',2),('japan','rock',1.5),('japan','classical',1.5),
  ('india','indian',5),('india','pop',2),('india','edm',1),
  ('france','french',4),('france','pop',2),('france','jazz',2),
  ('sweden','swedish',3),('sweden','pop',3),('sweden','heavy-metal',2.5),('sweden','edm',2),
  ('australia','rock',3),('australia','pop',2.5),('australia','country',2),('australia','edm',2);

-- вес часа суток (вечерний пик)
CREATE TEMP TABLE hour_cfg (h int, w float8);
INSERT INTO hour_cfg SELECT h, (ARRAY[1,1,1,1,1,1,2,4,5,4,3,3,4,4,3,3,4,5,6,8,9,9,6,3])[h+1] FROM generate_series(0,23) h;

-- 3. Каталог треков: по 300 самых популярных в каждом из 16 жанров ---------
CREATE TEMP TABLE top_tracks AS
WITH clean AS (
  SELECT DISTINCT ON (track_id)
         track_id,
         btrim(regexp_replace(split_part(artists, ';', 1), '[",;\t\r\n]+', ' ', 'g')) AS artist,
         btrim(regexp_replace(album_name, '[",;\t\r\n]+', ' ', 'g'))                   AS album,
         btrim(regexp_replace(track_name, '[",;\t\r\n]+', ' ', 'g'))                   AS track,
         track_genre, popularity, duration_ms / 1000 AS length_sec
  FROM raw_tracks
  WHERE track_genre IN (SELECT name FROM gen_cfg)
    AND duration_ms BETWEEN 60000 AND 600000
    AND artists IS NOT NULL AND album_name IS NOT NULL AND track_name IS NOT NULL
  ORDER BY track_id, popularity DESC, track_genre
), uniq AS (
  SELECT DISTINCT ON (track, artist) *
  FROM clean WHERE track <> '' AND artist <> '' AND album <> ''
  ORDER BY track, artist, popularity DESC, track_id
), ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY track_genre ORDER BY popularity DESC, track_id) AS rk
  FROM uniq
)
SELECT * FROM ranked WHERE rk <= 300;

INSERT INTO Artists (id, name, country_id)
SELECT ROW_NUMBER() OVER (ORDER BY artist) - 1, artist, MOD(ABS(HASHTEXT(artist)::bigint), 8)  -- страна исполнителя синтетическая
FROM (SELECT DISTINCT artist FROM top_tracks) a;

INSERT INTO Albums (id, name, artist_id)
SELECT ROW_NUMBER() OVER (ORDER BY ar.id, t.album) - 1, t.album, ar.id
FROM (SELECT DISTINCT artist, album FROM top_tracks) t JOIN Artists ar ON ar.name = t.artist;

INSERT INTO Songs (id, name, artist_id, album_id, genre_id, length_sec)
SELECT ROW_NUMBER() OVER (ORDER BY t.track_genre, t.rk) - 1, t.track, ar.id, al.id, g.id, t.length_sec
FROM top_tracks t
JOIN Artists ar ON ar.name = t.artist
JOIN Albums  al ON al.artist_id = ar.id AND al.name = t.album
JOIN Genres  g  ON g.name = t.track_genre;

-- 4. Кумулятивные веса для взвешенного выбора -------------------------------
-- выбор: берем u = random()*total и ищем первую строку с cum >= u (индекс по cum)
CREATE TEMP TABLE cg_cum AS      -- жанры внутри страны
SELECT country_id, genre_id,
       SUM(w) OVER (PARTITION BY country_id ORDER BY genre_id) AS cum,
       SUM(w) OVER (PARTITION BY country_id)                   AS total
FROM (SELECT c.id AS country_id, g.id AS genre_id,
             COALESCE(b.w, CASE WHEN g.is_global THEN 1.0 ELSE 0.2 END) AS w
      FROM Countries c CROSS JOIN gen_cfg g
      LEFT JOIN boost b ON b.country = c.name AND b.genre = g.name) x;
CREATE INDEX ON cg_cum (country_id, cum);

CREATE TEMP TABLE song_cum AS    -- песни внутри жанра: закон Ципфа 1/rank^0.8
SELECT s.genre_id, s.id AS song_id,
       SUM(1.0 / POWER(t.rk, 0.8)) OVER (PARTITION BY s.genre_id ORDER BY t.rk) AS cum,
       SUM(1.0 / POWER(t.rk, 0.8)) OVER (PARTITION BY s.genre_id)               AS total
FROM Songs s JOIN Artists ar ON ar.id = s.artist_id
JOIN top_tracks t ON t.track = s.name AND t.artist = ar.name;
CREATE INDEX ON song_cum (genre_id, cum);

CREATE TEMP TABLE hour_cum AS
SELECT h, SUM(w) OVER (ORDER BY h) AS cum, SUM(w) OVER () AS total FROM hour_cfg;

-- 5. Пользователи: 3000 штук, страна по долям, активность ~ экспоненциальная
CREATE TEMP TABLE country_cum AS
SELECT country_id, SUM(w) OVER (ORDER BY country_id) AS cum, SUM(w) OVER () AS total FROM country_cfg;

INSERT INTO Users (id, name, country_id)
SELECT u.g, 'user_' || LPAD(u.g::text, 4, '0'), c.country_id
FROM (SELECT g, RANDOM() AS r FROM GENERATE_SERIES(0, 2999) g OFFSET 0) u
CROSS JOIN LATERAL (SELECT country_id FROM country_cum WHERE cum >= u.r * total ORDER BY cum LIMIT 1) c;

CREATE TEMP TABLE user_cum AS
SELECT user_id, country_id, SUM(act) OVER (ORDER BY user_id) AS cum, SUM(act) OVER () AS total
FROM (SELECT id AS user_id, country_id, -LN(1 - RANDOM()) + 0.02 AS act FROM Users) x;
CREATE INDEX ON user_cum (cum);

-- 6. События ----------------------------------------------------------------
-- параметры: доли устройств mobile .55 / desktop .30 / smart_speaker .15;
-- вероятность скипа (<30 c): mobile .35, desktop .20, speaker .10, Япония -0.05, Бразилия +0.03;
-- у не-скипа доля дослушивания ~ U(lo,1): mobile .55, desktop .70, speaker .75; лайк 8% у не-скипов
CREATE TEMP TABLE ev AS
SELECT g AS event_id,
       RANDOM() AS r_user, RANDOM() AS r_genre, RANDOM() AS r_song, RANDOM() AS r_hour, RANDOM() AS r_dev,
       RANDOM() AS r_skip, RANDOM() AS r_frac,  RANDOM() AS r_like,
       FLOOR(RANDOM() * 61)::int AS day_n, FLOOR(RANDOM() * 3600)::int AS sec_n, 3 + FLOOR(RANDOM() * 27)::int AS skip_sec
FROM GENERATE_SERIES(0, 119999) g;

INSERT INTO Listens (id, ts, user_id, song_id, device, listened_sec, liked)
WITH picked AS (
  SELECT e.*, u.user_id, u.country_id, gn.genre_id, sg.song_id, hr.h,
         CASE WHEN e.r_dev < 0.55 THEN 'mobile' WHEN e.r_dev < 0.85 THEN 'desktop' ELSE 'smart_speaker' END AS device
  FROM ev e
  CROSS JOIN LATERAL (SELECT user_id, country_id FROM user_cum WHERE cum >= e.r_user * total ORDER BY cum LIMIT 1) u
  CROSS JOIN LATERAL (SELECT genre_id FROM cg_cum WHERE country_id = u.country_id AND cum >= e.r_genre * total ORDER BY cum LIMIT 1) gn
  CROSS JOIN LATERAL (SELECT song_id FROM song_cum WHERE genre_id = gn.genre_id AND cum >= e.r_song * total ORDER BY cum LIMIT 1) sg
  CROSS JOIN LATERAL (SELECT h FROM hour_cum WHERE cum >= e.r_hour * total ORDER BY cum LIMIT 1) hr
), flagged AS (
  SELECT p.*, s.length_sec,
         p.r_skip < (CASE p.device WHEN 'mobile' THEN 0.35 WHEN 'desktop' THEN 0.20 ELSE 0.10 END
                     + CASE p.country_id WHEN 5 THEN -0.05 WHEN 1 THEN 0.03 ELSE 0 END) AS is_skip,
         CASE p.device WHEN 'mobile' THEN 0.55 WHEN 'desktop' THEN 0.70 ELSE 0.75 END AS lo
  FROM picked p JOIN Songs s ON s.id = p.song_id
)
SELECT event_id,
       TIMESTAMP '2026-09-01' + day_n * INTERVAL '1 day' + h * INTERVAL '1 hour' + sec_n * INTERVAL '1 second',
       user_id, song_id, device,
       CASE WHEN is_skip THEN skip_sec
            ELSE LEAST(length_sec, GREATEST(30, ROUND(length_sec * (lo + (1.0 - lo) * r_frac))::int)) END,
       (NOT is_skip) AND r_like < 0.08
FROM flagged;

-- 7. Производные таблицы (вместо триггеров: массово и быстро) ----------------
UPDATE Songs   s SET popularity = c.n FROM (SELECT song_id, COUNT(*) n FROM Listens GROUP BY 1) c WHERE s.id = c.song_id;
UPDATE Artists a SET popularity = c.n FROM (SELECT s.artist_id id, SUM(popularity) n FROM Songs s GROUP BY 1) c WHERE a.id = c.id;
UPDATE Albums  a SET popularity = c.n FROM (SELECT s.album_id  id, SUM(popularity) n FROM Songs s GROUP BY 1) c WHERE a.id = c.id;
UPDATE Genres  g SET popularity = c.n FROM (SELECT s.genre_id  id, SUM(popularity) n FROM Songs s GROUP BY 1) c WHERE g.id = c.id;

INSERT INTO Liked_songs (id, user_id, song_id)
SELECT ROW_NUMBER() OVER (ORDER BY user_id, song_id) - 1, user_id, song_id
FROM (SELECT DISTINCT user_id, song_id FROM Listens WHERE liked) l;

-- 8. Проверки целостности ---------------------------------------------------
DO $$
BEGIN
  IF (SELECT COUNT(*) FROM Listens) <> 120000 THEN RAISE EXCEPTION 'wrong number of events'; END IF;
  IF EXISTS (SELECT 1 FROM Listens l JOIN Songs s ON s.id = l.song_id WHERE l.listened_sec > s.length_sec) THEN
    RAISE EXCEPTION 'listened_sec > length_sec'; END IF;
  IF (SELECT SUM(popularity) FROM Genres) <> 120000 THEN RAISE EXCEPTION 'genre popularity mismatch'; END IF;
END $$;

-- 9. Экспорт ------------------------------------------------------------------
CREATE TEMP VIEW listens_export AS
SELECT l.id AS event_id, TO_CHAR(l.ts, 'YYYY-MM-DD HH24:MI:SS') AS ts, l.user_id, c.name AS country,
       l.song_id, s.name AS song_name, ar.name AS artist, g.name AS genre, l.device,
       l.listened_sec, s.length_sec AS song_len_sec, l.liked::int AS liked
FROM Listens l
JOIN Users u ON u.id = l.user_id JOIN Countries c ON c.id = u.country_id
JOIN Songs s ON s.id = l.song_id JOIN Artists ar ON ar.id = s.artist_id JOIN Genres g ON g.id = s.genre_id;

\copy (SELECT * FROM listens_export ORDER BY event_id) TO 'listens.csv' CSV HEADER

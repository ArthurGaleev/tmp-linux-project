-- ============================================================================
-- schema.sql - схема БД стримингового сервиса (PostgreSQL).
-- Основана на Music-database/msdb_demo_init.sql.
-- Отличия от исходной схемы помечены комментариями FIX (исправление) и NEW (добавлено).
-- ============================================================================
DROP TABLE IF EXISTS Listens, Liked_songs, User_playlists, Songs, Albums, Artists, Users, Genres, Countries CASCADE;

CREATE TABLE Countries (
  id   SMALLINT    NOT NULL PRIMARY KEY,
  name VARCHAR(64) NOT NULL UNIQUE
);

CREATE TABLE Genres (
  id         SMALLINT    NOT NULL PRIMARY KEY,
  name       VARCHAR(64) NOT NULL UNIQUE,
  popularity BIGINT      NOT NULL DEFAULT 0
);

CREATE TABLE Artists (
  id         BIGINT      NOT NULL PRIMARY KEY,           -- FIX: было "NULL PRIMARY KEY" (противоречие)
  name       TEXT        NOT NULL,
  country_id SMALLINT    NOT NULL REFERENCES Countries(id) ON DELETE CASCADE ON UPDATE CASCADE,
  popularity BIGINT      NOT NULL DEFAULT 0
);

CREATE TABLE Albums (
  id         BIGINT      NOT NULL PRIMARY KEY,
  name       TEXT        NOT NULL,
  artist_id  BIGINT      NOT NULL REFERENCES Artists(id) ON DELETE CASCADE ON UPDATE CASCADE,
  popularity BIGINT      NOT NULL DEFAULT 0
  -- FIX: убран массив song_ids: он нигде не заполнялся, а список песен альбома
  -- и так получается из Songs.album_id
);

CREATE TABLE Songs (
  id         BIGINT      NOT NULL PRIMARY KEY,
  name       TEXT        NOT NULL,                      -- FIX: убран UNIQUE(name): у реальных треков названия повторяются
  artist_id  BIGINT      NOT NULL REFERENCES Artists(id) ON DELETE CASCADE ON UPDATE CASCADE,
  album_id   BIGINT      NOT NULL REFERENCES Albums(id)  ON DELETE CASCADE ON UPDATE CASCADE,
  genre_id   SMALLINT    NOT NULL REFERENCES Genres(id)  ON DELETE CASCADE ON UPDATE CASCADE,
  length_sec INTEGER     NOT NULL CHECK (length_sec > 0), -- NEW: длительность трека
  popularity BIGINT      NOT NULL DEFAULT 0
);

CREATE TABLE Users (
  id                   BIGINT      NOT NULL PRIMARY KEY,
  name                 VARCHAR(64) NOT NULL UNIQUE,
  country_id           SMALLINT    NOT NULL REFERENCES Countries(id) ON DELETE CASCADE ON UPDATE CASCADE,
  song_ids_history     BIGINT[],
  playlist_ids_history BIGINT[]
);

CREATE TABLE User_playlists (
  id         BIGINT      NOT NULL PRIMARY KEY,
  name       VARCHAR(64) NOT NULL,
  private    BOOLEAN     NOT NULL DEFAULT TRUE,
  user_id    BIGINT      NOT NULL REFERENCES Users(id) ON DELETE CASCADE ON UPDATE CASCADE,
  song_ids   BIGINT[],
  popularity BIGINT      NOT NULL DEFAULT 0,
  UNIQUE (user_id, name)                                 -- FIX: было UNIQUE(name) на весь сервис
);

CREATE TABLE Liked_songs (
  id      BIGINT NOT NULL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES Users(id) ON DELETE CASCADE ON UPDATE CASCADE,
  song_id BIGINT NOT NULL REFERENCES Songs(id) ON DELETE CASCADE ON UPDATE CASCADE, -- FIX: не было FK
  UNIQUE (user_id, song_id)                              -- FIX: в демо-данных лайки дублировались
);

-- NEW: журнал прослушиваний (событие = одна строка). Именно он выгружается в listens.csv.
CREATE TABLE Listens (
  id           BIGINT      NOT NULL PRIMARY KEY,
  ts           TIMESTAMP   NOT NULL,
  user_id      BIGINT      NOT NULL REFERENCES Users(id) ON DELETE CASCADE,
  song_id      BIGINT      NOT NULL REFERENCES Songs(id) ON DELETE CASCADE,
  device       VARCHAR(16) NOT NULL CHECK (device IN ('mobile', 'desktop', 'smart_speaker')),
  listened_sec INTEGER     NOT NULL CHECK (listened_sec >= 0),
  liked        BOOLEAN     NOT NULL DEFAULT FALSE
);
CREATE INDEX listens_song_idx ON Listens (song_id);
CREATE INDEX listens_user_idx ON Listens (user_id);

-- ---------------------------------------------------------------------------
-- Триггеры популярности (логика сохранена; FIX: срабатывают, только если история выросла)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_composition_popularity() RETURNS trigger AS $$
DECLARE
  last_song_id BIGINT := NEW.song_ids_history[ARRAY_LENGTH(NEW.song_ids_history, 1)];
BEGIN
  UPDATE Songs   SET popularity = popularity + 1 WHERE id = last_song_id;
  UPDATE Artists SET popularity = popularity + 1 WHERE id = (SELECT artist_id FROM Songs WHERE id = last_song_id);
  UPDATE Albums  SET popularity = popularity + 1 WHERE id = (SELECT album_id  FROM Songs WHERE id = last_song_id);
  UPDATE Genres  SET popularity = popularity + 1 WHERE id = (SELECT genre_id  FROM Songs WHERE id = last_song_id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS song_listened ON Users;
CREATE TRIGGER song_listened
AFTER UPDATE OF song_ids_history ON Users
FOR EACH ROW
WHEN (COALESCE(CARDINALITY(NEW.song_ids_history), 0) > COALESCE(CARDINALITY(OLD.song_ids_history), 0))
EXECUTE PROCEDURE update_composition_popularity();

CREATE OR REPLACE FUNCTION update_playlist_popularity() RETURNS trigger AS $$
BEGIN
  UPDATE User_playlists SET popularity = popularity + 1
  WHERE id = NEW.playlist_ids_history[ARRAY_LENGTH(NEW.playlist_ids_history, 1)];
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS playlist_listened ON Users;
CREATE TRIGGER playlist_listened
AFTER UPDATE OF playlist_ids_history ON Users
FOR EACH ROW
WHEN (COALESCE(CARDINALITY(NEW.playlist_ids_history), 0) > COALESCE(CARDINALITY(OLD.playlist_ids_history), 0))
EXECUTE PROCEDURE update_playlist_popularity();

-- ---------------------------------------------------------------------------
-- Функции (параметры с префиксом p_, чтобы не путать с колонками)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION listen_song(p_user_id BIGINT, p_song_id BIGINT) RETURNS VOID AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM Songs WHERE id = p_song_id) THEN       -- FIX: проверка существования
    RAISE EXCEPTION 'Song % does not exist', p_song_id;
  END IF;
  UPDATE Users SET song_ids_history = ARRAY_APPEND(song_ids_history, p_song_id) WHERE id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'User % does not exist', p_user_id; END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION listen_playlist(p_user_id BIGINT, p_playlist_id BIGINT) RETURNS VOID AS $$
DECLARE
  v_private BOOLEAN;
  v_owner   BIGINT;
BEGIN
  SELECT private, user_id INTO v_private, v_owner FROM User_playlists WHERE id = p_playlist_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Playlist % does not exist', p_playlist_id; END IF;   -- FIX
  IF v_private AND v_owner <> p_user_id THEN                                              -- FIX: владелец может слушать свой приватный плейлист
    RAISE EXCEPTION 'This playlist is for private use only';
  END IF;
  UPDATE Users SET playlist_ids_history = ARRAY_APPEND(playlist_ids_history, p_playlist_id) WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_playlist(p_name VARCHAR(64), p_private BOOLEAN, p_user_id BIGINT, p_song_ids BIGINT[])
RETURNS VOID AS $$
DECLARE
  new_id BIGINT;
BEGIN
  SELECT COALESCE(MAX(id), -1) + 1 INTO new_id FROM User_playlists;   -- FIX: было MAX((SELECT id ...)) -> ошибка при >1 строки
  INSERT INTO User_playlists (id, name, private, user_id, song_ids)
  VALUES (new_id, p_name, p_private, p_user_id, p_song_ids);
  PERFORM listen_playlist(p_user_id, new_id);                          -- создатель - первый слушатель
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION like_song(p_user_id BIGINT, p_song_id BIGINT) RETURNS VOID AS $$
DECLARE
  new_id BIGINT;
BEGIN
  SELECT COALESCE(MAX(id), -1) + 1 INTO new_id FROM Liked_songs;       -- FIX: та же ошибка с MAX
  INSERT INTO Liked_songs (id, user_id, song_id) VALUES (new_id, p_user_id, p_song_id)
  ON CONFLICT (user_id, song_id) DO NOTHING;                           -- FIX: повторный лайк не дублируется
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION user_id_by_name(p_name VARCHAR(64)) RETURNS BIGINT AS $$
  SELECT id FROM Users WHERE name = p_name;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION song_id_by_name(p_name TEXT) RETURNS BIGINT AS $$
  SELECT id FROM Songs WHERE name = p_name ORDER BY id LIMIT 1;        -- FIX: имена песен больше не уникальны
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION playlist_id_by_name(p_user_id BIGINT, p_name VARCHAR(64)) RETURNS BIGINT AS $$
  SELECT id FROM User_playlists WHERE user_id = p_user_id AND name = p_name;   -- FIX: было обращение к несуществующей таблице Playlist
$$ LANGUAGE sql;

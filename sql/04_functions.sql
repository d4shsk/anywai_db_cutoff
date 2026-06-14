
-- 1. fn_user_message_count — число сообщений пользователя за период.

-- Считаем только сообщения роли 'user' — это интересует аналитика, а не
-- ответы модели.
-- Если границы даты не заданы, считаем за всё время.

CREATE OR REPLACE FUNCTION fn_user_message_count(
    p_user_id BIGINT,
    p_from    TIMESTAMPTZ DEFAULT NULL,
    p_to      TIMESTAMPTZ DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COUNT(*)::BIGINT
      FROM messages m
      JOIN dialogues d ON d.id = m.dialogue_id
     WHERE d.user_id = p_user_id
       AND m.role    = 'user'
       AND (p_from IS NULL OR m.created_at >= p_from)
       AND (p_to   IS NULL OR m.created_at <  p_to);
$$;

COMMENT ON FUNCTION fn_user_message_count(BIGINT, TIMESTAMPTZ, TIMESTAMPTZ)
    IS 'Возвращает число сообщений роли user за период (NULL = без границы).';


-- 2. fn_dialogue_token_total — суммарные токены всех ответов модели в диалоге.

-- Используется для оценки стоимости диалога, прогноза квоты, ограничений.

CREATE OR REPLACE FUNCTION fn_dialogue_token_total(p_dialogue_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(SUM(COALESCE(tokens_in, 0) + COALESCE(tokens_out, 0)), 0)::BIGINT
      FROM messages
     WHERE dialogue_id = p_dialogue_id;
$$;

COMMENT ON FUNCTION fn_dialogue_token_total(BIGINT)
    IS 'Суммарные токены (in + out) всех сообщений диалога.';


-- 3. fn_top_models — самые популярные модели за период.

-- Возвращает таблицу: код модели, отображаемое имя, число использований.
-- p_limit ограничивает выдачу.
CREATE OR REPLACE FUNCTION fn_top_models(
    p_from  TIMESTAMPTZ DEFAULT NULL,
    p_to    TIMESTAMPTZ DEFAULT NULL,
    p_limit INTEGER     DEFAULT 10
)
RETURNS TABLE (
    model_code   VARCHAR(64),
    display_name VARCHAR(64),
    family       VARCHAR(32),
    usage_count  BIGINT
)
LANGUAGE sql
STABLE
AS $$
    SELECT lm.code,
           lm.display_name,
           lm.family,
           COUNT(*)::BIGINT AS usage_count
      FROM messages m
      JOIN llm_models lm ON lm.id = m.model_id
     WHERE m.role = 'assistant'
       AND (p_from IS NULL OR m.created_at >= p_from)
       AND (p_to   IS NULL OR m.created_at <  p_to)
     GROUP BY lm.id, lm.code, lm.display_name, lm.family
     ORDER BY usage_count DESC, lm.code
     LIMIT GREATEST(p_limit, 1);
$$;

COMMENT ON FUNCTION fn_top_models(TIMESTAMPTZ, TIMESTAMPTZ, INTEGER)
    IS 'Топ моделей по числу использований за период.';


-- 4. fn_user_active_days — число активных дней пользователя за период.

-- Активным считается день, в который пользователь отправил хотя бы одно
-- сообщение роли 'user'. Для DAU/WAU/MAU метрик.
CREATE OR REPLACE FUNCTION fn_user_active_days(
    p_user_id BIGINT,
    p_from    TIMESTAMPTZ,
    p_to      TIMESTAMPTZ
)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
    SELECT COUNT(DISTINCT (m.created_at AT TIME ZONE 'UTC')::DATE)::INTEGER
      FROM messages m
      JOIN dialogues d ON d.id = m.dialogue_id
     WHERE d.user_id   = p_user_id
       AND m.role      = 'user'
       AND m.created_at >= p_from
       AND m.created_at <  p_to;
$$;

COMMENT ON FUNCTION fn_user_active_days(BIGINT, TIMESTAMPTZ, TIMESTAMPTZ)
    IS 'Число уникальных дней (UTC), в которые пользователь писал сообщения.';


-- 5. fn_dialogue_message_count — число сообщений в диалоге.

-- Простая утилита, удобно вызывать в SELECT-списке вместо коррелированного
-- подзапроса.
CREATE OR REPLACE FUNCTION fn_dialogue_message_count(p_dialogue_id BIGINT)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
    SELECT COUNT(*)::INTEGER
      FROM messages
     WHERE dialogue_id = p_dialogue_id;
$$;

COMMENT ON FUNCTION fn_dialogue_message_count(BIGINT)
    IS 'Число сообщений в диалоге, всех ролей.';

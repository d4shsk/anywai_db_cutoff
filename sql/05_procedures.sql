
-- В PostgreSQL процедура (CREATE PROCEDURE) отличается от функции тем, что:
--   * вызывается через CALL, а не из SELECT;
--   * может управлять транзакциями (COMMIT/ROLLBACK внутри);
--   * не возвращает значение в общем смысле, но может писать в OUT-параметры.

-- 1. sp_register_user — UPSERT пользователя по telegram_id.
-- Если пользователя нет — создаём; если есть — обновляем username/имя/язык.
-- В OUT-параметре возвращаем внутренний id.

CREATE OR REPLACE PROCEDURE sp_register_user(
    p_telegram_id    BIGINT,
    p_username       VARCHAR(64),
    p_first_name     VARCHAR(128),
    p_last_name      VARCHAR(128),
    p_language_code  VARCHAR(8) DEFAULT 'ru',
    INOUT p_user_id  BIGINT     DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO users (
        telegram_id, username, first_name, last_name, language_code
    ) VALUES (
        p_telegram_id, p_username, p_first_name, p_last_name, p_language_code
    )
    ON CONFLICT (telegram_id) DO UPDATE
        SET username      = EXCLUDED.username,
            first_name    = EXCLUDED.first_name,
            last_name     = EXCLUDED.last_name,
            language_code = EXCLUDED.language_code,
            last_seen_at  = NOW()
    RETURNING id INTO p_user_id;
END;
$$;

COMMENT ON PROCEDURE sp_register_user(BIGINT, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BIGINT)
    IS 'UPSERT пользователя по telegram_id; возвращает внутренний id в OUT-параметре.';

-- 2. sp_create_dialogue — создание нового диалога.
CREATE OR REPLACE PROCEDURE sp_create_dialogue(
    p_user_id          BIGINT,
    p_title            VARCHAR(255) DEFAULT 'Новый диалог',
    INOUT p_dialogue_id BIGINT      DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO dialogues (user_id, title)
    VALUES (p_user_id, p_title)
    RETURNING id INTO p_dialogue_id;
END;
$$;

-- 3. sp_compact_dialogue — свёртка длинного диалога.
-- Идея: когда история слишком длинная для контекста модели, всё, что
-- было до p_until_message_id включительно, заменяется одной строкой свёртки.
--   * dialogue_summaries обновляется (UPSERT);
--   * сами строки messages с id <= p_until_message_id удаляются;
--   * пишется событие context_pressure_detected.

CREATE OR REPLACE PROCEDURE sp_compact_dialogue(
    p_dialogue_id        BIGINT,
    p_summary            TEXT,
    p_until_message_id   BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id        BIGINT;
    v_kind_id        SMALLINT;
    v_deleted_count  INTEGER;
BEGIN
    -- Проверка: указанное сообщение действительно из этого диалога.
    IF NOT EXISTS (
        SELECT 1 FROM messages
         WHERE id = p_until_message_id
           AND dialogue_id = p_dialogue_id
    ) THEN
        RAISE EXCEPTION
            'message % does not belong to dialogue %',
            p_until_message_id, p_dialogue_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- UPSERT свёртки.
    INSERT INTO dialogue_summaries (
        dialogue_id, summary, summarized_until_message_id, updated_at
    ) VALUES (
        p_dialogue_id, p_summary, p_until_message_id, NOW()
    )
    ON CONFLICT (dialogue_id) DO UPDATE
        SET summary                     = EXCLUDED.summary,
            summarized_until_message_id = EXCLUDED.summarized_until_message_id,
            updated_at                  = NOW();

    -- Удаление старых сообщений, кроме того, на котором стоит свёртка
    -- (его оставляем, чтобы FK на summarized_until_message_id остался валидным).
    DELETE FROM messages
     WHERE dialogue_id = p_dialogue_id
       AND id <  p_until_message_id;

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

    -- Событие.
    SELECT user_id INTO v_user_id FROM dialogues WHERE id = p_dialogue_id;
    SELECT id      INTO v_kind_id FROM event_kinds WHERE code = 'context_pressure_detected';

    IF v_kind_id IS NOT NULL THEN
        INSERT INTO analytics_events (
            user_id, dialogue_id, event_kind_id, source, properties_json
        ) VALUES (
            v_user_id, p_dialogue_id, v_kind_id, 'system',
            jsonb_build_object(
                'action',          'compact_dialogue',
                'until_message',   p_until_message_id,
                'deleted_messages', v_deleted_count,
                'summary_chars',   length(p_summary)
            )
        );
    END IF;
END;
$$;

-- 4. sp_archive_old_dialogues — массовая архивация диалогов без активности.

-- Сценарий обслуживания: ежемесячный «cron» проходит по диалогам, которые
-- не обновлялись больше N дней, и помечает их is_archived = TRUE.
-- В OUT-параметре возвращаем количество затронутых строк.
CREATE OR REPLACE PROCEDURE sp_archive_old_dialogues(
    p_days                  INTEGER,
    INOUT p_archived_count  INTEGER DEFAULT 0
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_days <= 0 THEN
        RAISE EXCEPTION 'p_days must be positive (got %)', p_days
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE dialogues
       SET is_archived = TRUE
     WHERE NOT is_archived
       AND updated_at < NOW() - (p_days * INTERVAL '1 day');

    GET DIAGNOSTICS p_archived_count = ROW_COUNT;
END;
$$;

-- 5. sp_log_event — единая точка записи в analytics_events.
-- Используется приложением, чтобы не дублировать INSERT и не ошибаться
-- с поиском event_kind_id по коду.
CREATE OR REPLACE PROCEDURE sp_log_event(
    p_user_id     BIGINT,
    p_dialogue_id BIGINT,
    p_event_code  VARCHAR(64),
    p_source      VARCHAR(32),
    p_properties  JSONB DEFAULT '{}'::jsonb
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_kind_id SMALLINT;
BEGIN
    SELECT id INTO v_kind_id
      FROM event_kinds
     WHERE code = p_event_code;

    IF v_kind_id IS NULL THEN
        RAISE EXCEPTION 'unknown event code: %', p_event_code
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO analytics_events (
        user_id, dialogue_id, event_kind_id, source, properties_json
    ) VALUES (
        p_user_id, p_dialogue_id, v_kind_id, p_source, p_properties
    );
END;
$$;

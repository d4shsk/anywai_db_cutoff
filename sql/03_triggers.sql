-- =============================================================================
-- Триггерные функции и триггеры
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Обновление dialogues.updated_at при любом UPDATE строки диалога.
-- -----------------------------------------------------------------------------
-- Назначение: гарантировать, что updated_at всегда отражает реальное
-- последнее изменение, даже если приложение забыло его выставить.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_dialogues_touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_dialogues_touch_updated_at ON dialogues;
CREATE TRIGGER trg_dialogues_touch_updated_at
    BEFORE UPDATE ON dialogues
    FOR EACH ROW
    EXECUTE FUNCTION trg_fn_dialogues_touch_updated_at();


-- -----------------------------------------------------------------------------
-- 2. После вставки сообщения — пнуть updated_at родительского диалога.
-- -----------------------------------------------------------------------------
-- Назначение: ix_dialogues_user_updated_at_desc отдаёт диалоги в порядке
-- активности; чтобы он был корректным, updated_at должен расти при каждом
-- новом сообщении.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_messages_touch_dialogue()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE dialogues
       SET updated_at = NOW()
     WHERE id = NEW.dialogue_id;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_messages_touch_dialogue ON messages;
CREATE TRIGGER trg_messages_touch_dialogue
    AFTER INSERT ON messages
    FOR EACH ROW
    EXECUTE FUNCTION trg_fn_messages_touch_dialogue();


-- -----------------------------------------------------------------------------
-- 3. После вставки сообщения — авто-логирование события message_sent.
-- -----------------------------------------------------------------------------
-- Назначение: централизованно писать в analytics_events, не полагаясь на
-- то, что приложение не забудет это сделать. Запись содержит только
-- метаданные (роль, длину текста, модель), а не сам текст сообщения.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_messages_log_event()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id BIGINT;
    v_kind_id SMALLINT;
BEGIN
    -- Подтянуть владельца диалога.
    SELECT user_id INTO v_user_id
      FROM dialogues
     WHERE id = NEW.dialogue_id;

    -- Найти id события message_sent в справочнике.
    SELECT id INTO v_kind_id
      FROM event_kinds
     WHERE code = 'message_sent';

    -- Если справочник ещё не наполнен (например, в самом начале сидинга),
    -- молча выходим: это не критичная для бизнеса операция.
    IF v_kind_id IS NULL THEN
        RETURN NEW;
    END IF;

    INSERT INTO analytics_events (
        user_id, dialogue_id, event_kind_id, source, occurred_at, properties_json
    ) VALUES (
        v_user_id,
        NEW.dialogue_id,
        v_kind_id,
        'system',
        NEW.created_at,
        jsonb_build_object(
            'role',         NEW.role,
            'model_id',     NEW.model_id,
            'tokens_in',    NEW.tokens_in,
            'tokens_out',   NEW.tokens_out,
            'content_len',  length(NEW.content)
        )
    );

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_messages_log_event ON messages;
CREATE TRIGGER trg_messages_log_event
    AFTER INSERT ON messages
    FOR EACH ROW
    EXECUTE FUNCTION trg_fn_messages_log_event();


-- -----------------------------------------------------------------------------
-- 4. Обновление users.last_seen_at по входящему сообщению.
-- -----------------------------------------------------------------------------
-- Назначение: показатель "последняя активность" должен обновляться без
-- участия приложения. Делаем только при роли 'user' — реакция модели сама
-- по себе не означает активности пользователя.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_messages_touch_user_last_seen()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.role <> 'user' THEN
        RETURN NEW;
    END IF;

    UPDATE users u
       SET last_seen_at = NEW.created_at
      FROM dialogues d
     WHERE d.id = NEW.dialogue_id
       AND u.id = d.user_id
       AND NEW.created_at > u.last_seen_at;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_messages_touch_user_last_seen ON messages;
CREATE TRIGGER trg_messages_touch_user_last_seen
    AFTER INSERT ON messages
    FOR EACH ROW
    EXECUTE FUNCTION trg_fn_messages_touch_user_last_seen();


-- -----------------------------------------------------------------------------
-- 5. Запрет UPDATE/DELETE в analytics_events (append-only гарантия на уровне БД).
-- -----------------------------------------------------------------------------
-- Назначение: журнал событий должен быть immutable. Приложение не должно
-- иметь возможности задним числом «подкрутить» аналитику, даже по ошибке.
--
-- Тонкость: внешние ключи user_id и dialogue_id объявлены ON DELETE SET NULL,
-- поэтому удаление пользователя или диалога порождает СИСТЕМНЫЙ UPDATE строки
-- журнала (обнуление FK). Такое изменение легитимно и должно проходить.
-- Поэтому триггер: всегда запрещает DELETE; при UPDATE разрешает единственное
-- изменение — обнуление user_id/dialogue_id, и блокирует любое другое.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_analytics_events_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'analytics_events is append-only: DELETE запрещён'
            USING ERRCODE = 'feature_not_supported';
    END IF;

    -- TG_OP = 'UPDATE': пропускаем только обнуление внешних ключей,
    -- вызванное ON DELETE SET NULL. Любое другое изменение запрещено.
    IF NEW.id            IS DISTINCT FROM OLD.id
    OR NEW.event_kind_id IS DISTINCT FROM OLD.event_kind_id
    OR NEW.source        IS DISTINCT FROM OLD.source
    OR NEW.occurred_at   IS DISTINCT FROM OLD.occurred_at
    OR NEW.properties_json IS DISTINCT FROM OLD.properties_json
    OR (NEW.user_id     IS DISTINCT FROM OLD.user_id     AND NEW.user_id     IS NOT NULL)
    OR (NEW.dialogue_id IS DISTINCT FROM OLD.dialogue_id AND NEW.dialogue_id IS NOT NULL)
    THEN
        RAISE EXCEPTION 'analytics_events is append-only: изменение запрещено'
            USING ERRCODE = 'feature_not_supported';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_analytics_events_immutable ON analytics_events;
CREATE TRIGGER trg_analytics_events_immutable
    BEFORE UPDATE OR DELETE ON analytics_events
    FOR EACH ROW
    EXECUTE FUNCTION trg_fn_analytics_events_immutable();

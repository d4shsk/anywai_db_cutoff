-- Чистый старт только для демонстрации
DROP TABLE IF EXISTS analytics_events       CASCADE;
DROP TABLE IF EXISTS event_kinds            CASCADE;
DROP TABLE IF EXISTS dialogue_summaries     CASCADE;
DROP TABLE IF EXISTS attachments            CASCADE;
DROP TABLE IF EXISTS messages               CASCADE;
DROP TABLE IF EXISTS dialogues              CASCADE;
DROP TABLE IF EXISTS llm_models             CASCADE;
DROP TABLE IF EXISTS llm_providers          CASCADE;
DROP TABLE IF EXISTS users                  CASCADE;

-- 1. users — пользователи AI-сервиса
-- telegram_id хранится отдельно от внутреннего id, потому что:
--   * внутренний id используется во всех FK и стабилен;
--   * telegram_id — внешний идентификатор, по нему ищем при логине.

CREATE TABLE users (
    id              BIGSERIAL       PRIMARY KEY,
    telegram_id     BIGINT          NOT NULL UNIQUE,
    username        VARCHAR(64),
    first_name      VARCHAR(128),
    last_name       VARCHAR(128),
    language_code   VARCHAR(8)      NOT NULL DEFAULT 'ru',
    registered_at   TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    last_seen_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_users_telegram_id_positive
        CHECK (telegram_id > 0),
    CONSTRAINT chk_users_language_code_lower
        CHECK (language_code = LOWER(language_code))
);

COMMENT ON TABLE  users                 IS 'Пользователи AI-сервиса (1:1 с Telegram-аккаунтом).';
COMMENT ON COLUMN users.telegram_id     IS 'Внешний идентификатор Telegram, не используется как PK.';
COMMENT ON COLUMN users.last_seen_at    IS 'Последняя зафиксированная активность; обновляется приложением или триггером.';


-- 2. llm_providers — справочник провайдеров LLM-моделей
-- Вынесли в отдельную таблицу, чтобы не дублировать строку 'Google'/'Anthropic'
-- в каждой строке llm_models. Это устраняет транзитивную зависимость и
-- даёт нам 3НФ.

CREATE TABLE llm_providers (
    id              SMALLSERIAL     PRIMARY KEY,
    code            VARCHAR(32)     NOT NULL UNIQUE,
    display_name    VARCHAR(64)     NOT NULL,

    CONSTRAINT chk_llm_providers_code_lower
        CHECK (code = LOWER(code))
);

COMMENT ON TABLE  llm_providers IS 'Справочник провайдеров LLM (google, anthropic, openai, groq).';


-- 3. llm_models — справочник LLM-моделей
CREATE TABLE llm_models (
    id              SMALLSERIAL     PRIMARY KEY,
    provider_id     SMALLINT        NOT NULL
                    REFERENCES llm_providers(id) ON DELETE RESTRICT,
    code            VARCHAR(64)     NOT NULL UNIQUE,
    display_name    VARCHAR(64)     NOT NULL,
    family          VARCHAR(32)     NOT NULL,
    is_premium      BOOLEAN         NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE,

    CONSTRAINT chk_llm_models_family_known
        CHECK (family IN ('gemini', 'claude', 'gpt', 'llama', 'other'))
);

COMMENT ON TABLE  llm_models            IS 'Справочник LLM-моделей, доступных пользователям.';
COMMENT ON COLUMN llm_models.code       IS 'Уникальный технический код модели (claude-opus-4-7).';
COMMENT ON COLUMN llm_models.is_premium IS 'TRUE — модель доступна только пользователям с подпиской.';


-- 4. dialogues — диалоги пользователя
CREATE TABLE dialogues (
    id              BIGSERIAL       PRIMARY KEY,
    user_id         BIGINT          NOT NULL
                    REFERENCES users(id) ON DELETE CASCADE,
    title           VARCHAR(255)    NOT NULL DEFAULT 'Новый диалог',
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    is_archived     BOOLEAN         NOT NULL DEFAULT FALSE,

    CONSTRAINT chk_dialogues_title_not_blank
        CHECK (length(btrim(title)) > 0),
    CONSTRAINT chk_dialogues_updated_after_created
        CHECK (updated_at >= created_at)
);

COMMENT ON TABLE  dialogues             IS 'Диалоги пользователя; один пользователь — много диалогов.';
COMMENT ON COLUMN dialogues.updated_at  IS 'Обновляется триггером trg_messages_touch_dialogue при добавлении сообщения.';
COMMENT ON COLUMN dialogues.is_archived IS 'Архивные диалоги не показываются в списке, но не удаляются.';


-- 5. messages — сообщения внутри диалога
-- model_id NULL для сообщений роли 'user' и 'system': их никакая модель не
-- генерировала. CHECK-ограничение гарантирует консистентность: у assistant
-- модель должна быть, у user — не должна.
CREATE TABLE messages (
    id              BIGSERIAL       PRIMARY KEY,
    dialogue_id     BIGINT          NOT NULL
                    REFERENCES dialogues(id) ON DELETE CASCADE,
    role            VARCHAR(16)     NOT NULL,
    content         TEXT            NOT NULL,
    model_id        SMALLINT        REFERENCES llm_models(id) ON DELETE RESTRICT,
    tokens_in       INTEGER,
    tokens_out      INTEGER,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_messages_role_known
        CHECK (role IN ('user', 'assistant', 'system')),
    CONSTRAINT chk_messages_content_not_empty
        CHECK (length(content) > 0),
    CONSTRAINT chk_messages_tokens_non_negative
        CHECK (
            (tokens_in  IS NULL OR tokens_in  >= 0)
            AND
            (tokens_out IS NULL OR tokens_out >= 0)
        ),
    CONSTRAINT chk_messages_assistant_has_model
        CHECK (
            (role = 'assistant' AND model_id IS NOT NULL)
            OR
            (role <> 'assistant' AND model_id IS NULL)
        )
);

COMMENT ON TABLE  messages              IS 'Сообщения внутри диалогов. Append-only с точки зрения приложения.';
COMMENT ON COLUMN messages.role         IS 'Кто сказал: user, assistant, system.';
COMMENT ON COLUMN messages.model_id     IS 'Модель, сгенерировавшая ответ; обязательна для assistant, запрещена для user/system.';


-- 6. attachments — метаданные вложений
-- Сами байты файлов в БД не храним: для этого есть объектное хранилище.
-- В таблице — только метаданные и хеш для дедупликации.
CREATE TABLE attachments (
    id              BIGSERIAL       PRIMARY KEY,
    message_id      BIGINT          NOT NULL
                    REFERENCES messages(id) ON DELETE CASCADE,
    kind            VARCHAR(16)     NOT NULL,
    file_name       VARCHAR(255)    NOT NULL,
    mime_type       VARCHAR(127)    NOT NULL,
    size_bytes      BIGINT          NOT NULL,
    sha256          CHAR(64)        NOT NULL,

    CONSTRAINT chk_attachments_kind_known
        CHECK (kind IN ('image', 'document', 'audio', 'video')),
    CONSTRAINT chk_attachments_size_non_negative
        CHECK (size_bytes >= 0),
    CONSTRAINT chk_attachments_sha256_hex
        CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT chk_attachments_file_name_not_blank
        CHECK (length(btrim(file_name)) > 0)
);

COMMENT ON TABLE  attachments       IS 'Метаданные файлов, прикреплённых к сообщению.';
COMMENT ON COLUMN attachments.sha256 IS 'SHA-256 содержимого в hex; используется для дедупликации.';


-- 7. dialogue_summaries — свёртка длинных диалогов
-- Отношение 1:1 к dialogues: один диалог имеет не более одной активной свёртки.
-- Когда история длинного диалога превышает контекст модели, старые сообщения
-- свёртываются в summary, а сами строки messages удаляются.
-- summarized_until_message_id — id последнего вошедшего в свёртку сообщения.

CREATE TABLE dialogue_summaries (
    dialogue_id                 BIGINT      PRIMARY KEY
                                REFERENCES dialogues(id) ON DELETE CASCADE,
    summary                     TEXT        NOT NULL,
    summarized_until_message_id BIGINT      NOT NULL
                                REFERENCES messages(id) ON DELETE RESTRICT,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_dialogue_summaries_summary_not_empty
        CHECK (length(summary) > 0)
);

COMMENT ON TABLE  dialogue_summaries IS 'Свёртки старых сообщений; одна на диалог.';


-- 8. event_kinds — справочник типов аналитических событий
-- Вынесли коды событий в справочник, чтобы:
--   * избежать опечаток в строковых литералах в коде приложения;
--   * иметь возможность дать человекочитаемое описание каждому коду;
--   * экономить место в analytics_events (FK на SMALLINT вместо TEXT).

CREATE TABLE event_kinds (
    id              SMALLSERIAL     PRIMARY KEY,
    code            VARCHAR(64)     NOT NULL UNIQUE,
    description     VARCHAR(255)    NOT NULL,

    CONSTRAINT chk_event_kinds_code_lower
        CHECK (code = LOWER(code))
);

COMMENT ON TABLE event_kinds IS 'Справочник типов аналитических событий.';


-- 9. analytics_events — append-only журнал событий

-- properties_json в JSONB сознательно: набор свойств у каждого типа события
-- свой и часто меняется. Делать на каждый тип отдельную таблицу было бы
-- негибко, делать одну плоскую таблицу со всеми возможными полями —
-- разреженно и неэкономно.

CREATE TABLE analytics_events (
    id              BIGSERIAL       PRIMARY KEY,
    user_id         BIGINT          REFERENCES users(id)      ON DELETE SET NULL,
    dialogue_id     BIGINT          REFERENCES dialogues(id)  ON DELETE SET NULL,
    event_kind_id   SMALLINT        NOT NULL
                    REFERENCES event_kinds(id) ON DELETE RESTRICT,
    source          VARCHAR(32)     NOT NULL,
    occurred_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    properties_json JSONB           NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT chk_events_source_known
        CHECK (source IN ('telegram', 'web', 'system', 'admin'))
);

COMMENT ON TABLE  analytics_events                 IS 'Append-only журнал поведенческих и системных событий.';
COMMENT ON COLUMN analytics_events.properties_json IS 'Дополнительные свойства события в формате JSON.';

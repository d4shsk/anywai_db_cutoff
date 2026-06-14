-- Индексы
-- UNIQUE-индексы на users.telegram_id, llm_providers.code, llm_models.code,
-- event_kinds.code, а также все PK-индексы создаются автоматически
-- определением UNIQUE/PRIMARY KEY в schema. Здесь — только дополнительные
-- индексы под конкретные сценарии.

-- 1. Список диалогов пользователя, отсортированный по последней активности.
--    Закрывает запрос: WHERE user_id = ? ORDER BY updated_at DESC.
--    Сортировка в самом индексе позволяет читать страницы без сортировки.
CREATE INDEX ix_dialogues_user_updated_at_desc
    ON dialogues (user_id, updated_at DESC);

-- 2. Только активные диалоги пользователя.
--    Частичный индекс, потому что архивных диалогов со временем больше,
--    а в UI показываем почти всегда активные. Индекс вдвое-впятеро меньше.
CREATE INDEX ix_dialogues_active_user
    ON dialogues (user_id)
    WHERE NOT is_archived;

-- 3. Чтение страницы сообщений диалога.
--    Закрывает: WHERE dialogue_id = ? ORDER BY created_at, id.
--    Включаем id вторым ключом, чтобы стабильно сортировать сообщения,
--    созданные в одну миллисекунду.
CREATE INDEX ix_messages_dialogue_created
    ON messages (dialogue_id, created_at, id);

-- 4. Сообщения по модели за период (аналитика «топ моделей за месяц»).
--    Покрывает: WHERE model_id = ? AND created_at BETWEEN ... AND ...
CREATE INDEX ix_messages_model_created
    ON messages (model_id, created_at)
    WHERE model_id IS NOT NULL;

-- 5. Вложения сообщения.
--    Закрывает FK-связь и быстрый JOIN messages → attachments.
CREATE INDEX ix_attachments_message
    ON attachments (message_id);

-- 6. Дедупликация и поиск по хешу.
--    Полезно при загрузке: «не загружали ли уже такой файл?»
CREATE INDEX ix_attachments_sha256
    ON attachments (sha256);

-- 7. Аналитика активности пользователя по времени.
--    «Все события пользователя за последние N дней»; «события одного типа».
CREATE INDEX ix_events_user_occurred
    ON analytics_events (user_id, occurred_at DESC);

CREATE INDEX ix_events_kind_occurred
    ON analytics_events (event_kind_id, occurred_at DESC);

-- 8. Поиск событий по полю внутри JSON.
--    GIN-индекс с оператор-классом jsonb_path_ops оптимизирован под
--    запросы вида: properties_json @> '{"key": "value"}'.
--    Размер меньше, чем у дефолтного jsonb_ops, но поддерживает только
--    оператор @>; для нашего сценария этого достаточно.
CREATE INDEX gin_events_properties
    ON analytics_events
    USING GIN (properties_json jsonb_path_ops);

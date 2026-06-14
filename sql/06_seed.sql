-- Тестовые данные
-- Небольшой набор для проверки всех типовых запросов.
-- Идемпотентность: используем ON CONFLICT, чтобы повторный запуск
-- не падал с дубликатами.

-- Провайдеры
INSERT INTO llm_providers (code, display_name) VALUES
    ('google',    'Google'),
    ('anthropic', 'Anthropic'),
    ('openai',    'OpenAI'),
    ('groq',      'Groq')
ON CONFLICT (code) DO NOTHING;

-- Модели
INSERT INTO llm_models (provider_id, code, display_name, family, is_premium, is_active) VALUES
    ((SELECT id FROM llm_providers WHERE code = 'google'),    'gemini-3-flash',     'Gemini 3 Flash',     'gemini', FALSE, TRUE),
    ((SELECT id FROM llm_providers WHERE code = 'google'),    'gemini-3.5-flash',   'Gemini 3.5 Flash',   'gemini', TRUE,  TRUE),
    ((SELECT id FROM llm_providers WHERE code = 'anthropic'), 'claude-sonnet-4-6',  'Claude Sonnet 4.6',  'claude', TRUE,  TRUE),
    ((SELECT id FROM llm_providers WHERE code = 'anthropic'), 'claude-opus-4-7',    'Claude Opus 4.7',    'claude', TRUE,  TRUE),
    ((SELECT id FROM llm_providers WHERE code = 'openai'),    'gpt-4o',             'GPT-4o',             'gpt',    TRUE,  TRUE),
    ((SELECT id FROM llm_providers WHERE code = 'groq'),      'llama-3.3-70b',      'Llama 3.3 70B',      'llama',  FALSE, TRUE)
ON CONFLICT (code) DO NOTHING;

-- Типы событий
INSERT INTO event_kinds (code, description) VALUES
    ('message_sent',              'Отправлено сообщение в диалоге'),
    ('dialogue_created',          'Создан новый диалог'),
    ('model_selected',            'Пользователь выбрал модель'),
    ('context_pressure_detected', 'Сработала свёртка истории'),
    ('user_registered',           'Регистрация нового пользователя'),
    ('attachment_uploaded',       'Прикреплён файл к сообщению')
ON CONFLICT (code) DO NOTHING;

-- Пользователи
INSERT INTO users (telegram_id, username, first_name, last_name, language_code, registered_at) VALUES
    (1001, 'alice',   'Алиса',  'Иванова', 'ru', NOW() - INTERVAL '40 days'),
    (1002, 'bob',     'Борис',  'Петров',  'ru', NOW() - INTERVAL '30 days'),
    (1003, 'carol',   'Кэрол',  NULL,      'en', NOW() - INTERVAL '15 days'),
    (1004, 'dmitry',  'Дмитрий', 'Сидоров', 'ru', NOW() - INTERVAL '5 days')
ON CONFLICT (telegram_id) DO NOTHING;

-- Диалоги. Используем подзапросы по telegram_id, чтобы не зависеть от автогенерации id.
INSERT INTO dialogues (user_id, title, created_at, updated_at) VALUES
    ((SELECT id FROM users WHERE telegram_id = 1001), 'Помощь с Python',     NOW() - INTERVAL '10 days', NOW() - INTERVAL '1 day'),
    ((SELECT id FROM users WHERE telegram_id = 1001), 'Идеи для презентации', NOW() - INTERVAL '5 days',  NOW() - INTERVAL '5 days'),
    ((SELECT id FROM users WHERE telegram_id = 1002), 'SQL-запросы',          NOW() - INTERVAL '8 days',  NOW() - INTERVAL '2 days'),
    ((SELECT id FROM users WHERE telegram_id = 1003), 'Translation help',     NOW() - INTERVAL '6 days',  NOW() - INTERVAL '6 days'),
    ((SELECT id FROM users WHERE telegram_id = 1004), 'Первые вопросы',       NOW() - INTERVAL '3 days',  NOW() - INTERVAL '3 days');

-- Сообщения для первого диалога Алисы.
WITH d AS (
    SELECT id FROM dialogues
     WHERE user_id = (SELECT id FROM users WHERE telegram_id = 1001)
       AND title   = 'Помощь с Python'
)
INSERT INTO messages (dialogue_id, role, content, model_id, tokens_in, tokens_out, created_at)
SELECT d.id, 'user',      'Как развернуть список на Python?', NULL, NULL, NULL, NOW() - INTERVAL '10 days' FROM d UNION ALL
SELECT d.id, 'assistant', 'reverse() или срез [::-1].',
       (SELECT id FROM llm_models WHERE code = 'claude-sonnet-4-6'),
       40, 30, NOW() - INTERVAL '10 days' + INTERVAL '5 seconds' FROM d UNION ALL
SELECT d.id, 'user',      'А разница между ними?', NULL, NULL, NULL,
       NOW() - INTERVAL '9 days' FROM d UNION ALL
SELECT d.id, 'assistant', 'reverse() меняет список на месте, [::-1] возвращает копию.',
       (SELECT id FROM llm_models WHERE code = 'claude-sonnet-4-6'),
       60, 80, NOW() - INTERVAL '9 days' + INTERVAL '4 seconds' FROM d UNION ALL
SELECT d.id, 'user',      'Спасибо', NULL, NULL, NULL, NOW() - INTERVAL '1 day' FROM d;

-- Сообщения для второго диалога Алисы.
WITH d AS (
    SELECT id FROM dialogues
     WHERE user_id = (SELECT id FROM users WHERE telegram_id = 1001)
       AND title   = 'Идеи для презентации'
)
INSERT INTO messages (dialogue_id, role, content, model_id, tokens_in, tokens_out, created_at)
SELECT d.id, 'user',      'Накидай тезисов про BI-системы.', NULL, NULL, NULL,
       NOW() - INTERVAL '5 days' FROM d UNION ALL
SELECT d.id, 'assistant', 'Тезис 1, тезис 2, тезис 3.',
       (SELECT id FROM llm_models WHERE code = 'gpt-4o'),
       120, 200, NOW() - INTERVAL '5 days' + INTERVAL '6 seconds' FROM d;

-- Диалог Бориса с парой моделей.
WITH d AS (
    SELECT id FROM dialogues
     WHERE user_id = (SELECT id FROM users WHERE telegram_id = 1002)
       AND title   = 'SQL-запросы'
)
INSERT INTO messages (dialogue_id, role, content, model_id, tokens_in, tokens_out, created_at)
SELECT d.id, 'user',      'Напиши пример GROUP BY ROLLUP.', NULL, NULL, NULL,
       NOW() - INTERVAL '8 days' FROM d UNION ALL
SELECT d.id, 'assistant', 'SELECT department, SUM(salary) FROM emp GROUP BY ROLLUP(department);',
       (SELECT id FROM llm_models WHERE code = 'claude-opus-4-7'),
       80, 60, NOW() - INTERVAL '8 days' + INTERVAL '3 seconds' FROM d UNION ALL
SELECT d.id, 'user',      'А оконные функции?', NULL, NULL, NULL,
       NOW() - INTERVAL '7 days' FROM d UNION ALL
SELECT d.id, 'assistant', 'ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...).',
       (SELECT id FROM llm_models WHERE code = 'gemini-3.5-flash'),
       50, 40, NOW() - INTERVAL '7 days' + INTERVAL '5 seconds' FROM d UNION ALL
SELECT d.id, 'user',      'Спасибо, понял.', NULL, NULL, NULL,
       NOW() - INTERVAL '2 days' FROM d;

-- Диалог Кэрол на английском.
WITH d AS (
    SELECT id FROM dialogues
     WHERE user_id = (SELECT id FROM users WHERE telegram_id = 1003)
       AND title   = 'Translation help'
)
INSERT INTO messages (dialogue_id, role, content, model_id, tokens_in, tokens_out, created_at)
SELECT d.id, 'user',      'Translate "доброе утро" to French.', NULL, NULL, NULL,
       NOW() - INTERVAL '6 days' FROM d UNION ALL
SELECT d.id, 'assistant', 'Bonjour.',
       (SELECT id FROM llm_models WHERE code = 'gemini-3-flash'),
       12, 8, NOW() - INTERVAL '6 days' + INTERVAL '2 seconds' FROM d;

-- Диалог Дмитрия с вложением.
WITH d AS (
    SELECT id FROM dialogues
     WHERE user_id = (SELECT id FROM users WHERE telegram_id = 1004)
       AND title   = 'Первые вопросы'
), m AS (
    INSERT INTO messages (dialogue_id, role, content, model_id, tokens_in, tokens_out, created_at)
    SELECT d.id, 'user', 'Опиши, что в этом PDF.', NULL, NULL, NULL,
           NOW() - INTERVAL '3 days' FROM d
    RETURNING id
)
INSERT INTO attachments (message_id, kind, file_name, mime_type, size_bytes, sha256)
SELECT m.id, 'document', 'report.pdf', 'application/pdf', 2048576,
       repeat('a', 64) FROM m;

-- Дополнительный assistant-ответ на вложение.
WITH d AS (
    SELECT id FROM dialogues
     WHERE user_id = (SELECT id FROM users WHERE telegram_id = 1004)
       AND title   = 'Первые вопросы'
)
INSERT INTO messages (dialogue_id, role, content, model_id, tokens_in, tokens_out, created_at)
SELECT d.id, 'assistant', 'PDF содержит финансовый отчёт за Q1.',
       (SELECT id FROM llm_models WHERE code = 'claude-opus-4-7'),
       2000, 200, NOW() - INTERVAL '3 days' + INTERVAL '8 seconds' FROM d;

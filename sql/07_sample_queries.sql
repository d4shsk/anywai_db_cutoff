-- =============================================================================
-- Типовые запросы — шпаргалка для защиты
-- =============================================================================
-- Каждый блок отвечает на один типовой бизнес-вопрос. Полезно прогнать их
-- руками с EXPLAIN ANALYZE и посмотреть, какие индексы используются.
-- =============================================================================


-- 1. Список диалогов пользователя с числом сообщений и временем последней активности.
--    Под этот запрос работает ix_dialogues_user_updated_at_desc.
SELECT d.id,
       d.title,
       d.created_at,
       d.updated_at,
       fn_dialogue_message_count(d.id) AS message_count
  FROM dialogues d
 WHERE d.user_id = 1
   AND NOT d.is_archived
 ORDER BY d.updated_at DESC
 LIMIT 20;


-- 2. Топ-10 пользователей по числу сообщений за последние 30 дней.
SELECT u.id,
       u.username,
       u.first_name,
       COUNT(*) AS message_count
  FROM messages m
  JOIN dialogues d ON d.id = m.dialogue_id
  JOIN users u     ON u.id = d.user_id
 WHERE m.role = 'user'
   AND m.created_at >= NOW() - INTERVAL '30 days'
 GROUP BY u.id, u.username, u.first_name
 ORDER BY message_count DESC
 LIMIT 10;


-- 3. Распределение сообщений по часам суток (UTC).
SELECT EXTRACT(HOUR FROM created_at AT TIME ZONE 'UTC') AS hour_utc,
       COUNT(*) AS message_count
  FROM messages
 WHERE created_at >= NOW() - INTERVAL '30 days'
 GROUP BY hour_utc
 ORDER BY hour_utc;


-- 4. Средняя длина диалога по семействам моделей.
--    Длина — число сообщений роли assistant в диалоге.
SELECT lm.family,
       ROUND(AVG(per_dialogue.cnt)::numeric, 2) AS avg_assistant_messages
  FROM (
        SELECT m.dialogue_id,
               m.model_id,
               COUNT(*) AS cnt
          FROM messages m
         WHERE m.role = 'assistant'
         GROUP BY m.dialogue_id, m.model_id
       ) per_dialogue
  JOIN llm_models lm ON lm.id = per_dialogue.model_id
 GROUP BY lm.family
 ORDER BY avg_assistant_messages DESC;


-- 5. Топ моделей за месяц через пользовательскую функцию.
SELECT *
  FROM fn_top_models(NOW() - INTERVAL '30 days', NOW(), 5);


-- 6. Пользователи, активные в этом месяце, но НЕ активные в прошлом
--    (возвращающаяся аудитория).
WITH this_month AS (
    SELECT DISTINCT d.user_id
      FROM messages m
      JOIN dialogues d ON d.id = m.dialogue_id
     WHERE m.role = 'user'
       AND m.created_at >= date_trunc('month', NOW())
), prev_month AS (
    SELECT DISTINCT d.user_id
      FROM messages m
      JOIN dialogues d ON d.id = m.dialogue_id
     WHERE m.role = 'user'
       AND m.created_at >= date_trunc('month', NOW()) - INTERVAL '1 month'
       AND m.created_at <  date_trunc('month', NOW())
)
SELECT u.id,
       u.username,
       u.first_name
  FROM this_month tm
  JOIN users u ON u.id = tm.user_id
 WHERE NOT EXISTS (SELECT 1 FROM prev_month p WHERE p.user_id = tm.user_id);


-- 7. Ранг сообщений внутри диалога (оконная функция).
--    Удобно при экспорте истории: показать «N-е сообщение в диалоге X».
SELECT id,
       dialogue_id,
       role,
       created_at,
       ROW_NUMBER() OVER (PARTITION BY dialogue_id ORDER BY created_at, id) AS msg_no
  FROM messages
 WHERE dialogue_id = 1
 ORDER BY msg_no;


-- 8. Поиск событий по полю в JSONB (использует gin_events_properties).
--    Все события, в которых модель — claude-opus-4-7.
SELECT id, occurred_at, source, properties_json
  FROM analytics_events
 WHERE properties_json @> jsonb_build_object(
        'model_id',
        (SELECT id FROM llm_models WHERE code = 'claude-opus-4-7')::int
       )
 ORDER BY occurred_at DESC
 LIMIT 50;


-- 9. Подсчёт активных дней пользователя за месяц через функцию.
SELECT u.id,
       u.username,
       fn_user_active_days(u.id, NOW() - INTERVAL '30 days', NOW()) AS active_days
  FROM users u
 ORDER BY active_days DESC
 LIMIT 10;


-- 10. Длинные сообщения с CTE: ассистентские ответы > 5000 символов
--     и в каких диалогах они появлялись.
WITH long_msgs AS (
    SELECT id, dialogue_id, length(content) AS content_len, created_at
      FROM messages
     WHERE role = 'assistant'
       AND length(content) > 5000
)
SELECT u.username,
       d.title,
       lm.content_len,
       lm.created_at
  FROM long_msgs lm
  JOIN dialogues d ON d.id = lm.dialogue_id
  JOIN users     u ON u.id = d.user_id
 ORDER BY lm.content_len DESC;


-- 11. ROLLUP: число сообщений по (роль, семейство модели) с подытогами.
SELECT m.role,
       lm.family,
       COUNT(*) AS cnt
  FROM messages m
  LEFT JOIN llm_models lm ON lm.id = m.model_id
 GROUP BY ROLLUP (m.role, lm.family)
 ORDER BY m.role NULLS LAST, lm.family NULLS LAST;


-- 12. Стоимость диалогов по токенам (LATERAL JOIN с функцией).
SELECT d.id,
       d.title,
       u.username,
       t.token_total
  FROM dialogues d
  JOIN users u ON u.id = d.user_id
  CROSS JOIN LATERAL (
        SELECT fn_dialogue_token_total(d.id) AS token_total
       ) t
 ORDER BY t.token_total DESC
 LIMIT 20;


-- 13. Серия дней (generate_series) с числом сообщений на каждый день месяца.
--    Закрывает дыры в датах: даже если в день не было сообщений, строка есть.
SELECT day::date AS day,
       COUNT(m.id) AS message_count
  FROM generate_series(
            date_trunc('day', NOW() - INTERVAL '14 days'),
            date_trunc('day', NOW()),
            INTERVAL '1 day'
       ) AS day
  LEFT JOIN messages m
         ON date_trunc('day', m.created_at) = day
        AND m.role = 'user'
 GROUP BY day
 ORDER BY day;


-- 14. Активность по семействам моделей за периоды (CASE-агрегация).
SELECT lm.family,
       SUM(CASE WHEN m.created_at >= NOW() - INTERVAL '7 days'  THEN 1 ELSE 0 END) AS last_7d,
       SUM(CASE WHEN m.created_at >= NOW() - INTERVAL '30 days' THEN 1 ELSE 0 END) AS last_30d,
       SUM(1) AS total
  FROM messages m
  JOIN llm_models lm ON lm.id = m.model_id
 WHERE m.role = 'assistant'
 GROUP BY lm.family
 ORDER BY last_30d DESC;


-- 15. EXISTS-фильтр: пользователи, прикреплявшие хотя бы один файл.
SELECT u.id, u.username, u.first_name
  FROM users u
 WHERE EXISTS (
        SELECT 1
          FROM attachments a
          JOIN messages m ON m.id = a.message_id
          JOIN dialogues d ON d.id = m.dialogue_id
         WHERE d.user_id = u.id
       );

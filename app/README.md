# CRUD REST API

Демонстрационное приложение к курсовому проекту: REST API над базой данных
истории диалогов AI-чат-сервиса. Стек — FastAPI + SQLAlchemy 2.0 + PostgreSQL.

## Запуск

1. Поднять PostgreSQL и накатить схему из каталога `../sql`:

   ```bash
   psql -h localhost -U postgres -f ../sql/01_schema.sql
   psql -h localhost -U postgres -f ../sql/02_indexes.sql
   psql -h localhost -U postgres -f ../sql/03_triggers.sql
   psql -h localhost -U postgres -f ../sql/04_functions.sql
   psql -h localhost -U postgres -f ../sql/05_procedures.sql
   psql -h localhost -U postgres -f ../sql/06_seed.sql
   ```

2. Установить зависимости и задать строку подключения:

   ```bash
   pip install -r requirements.txt
   set DATABASE_URL=postgresql+psycopg://postgres:postgres@localhost:5432/postgres
   ```

3. Запустить сервер:

   ```bash
   uvicorn main:app --reload
   ```

4. Открыть интерактивную документацию Swagger: http://localhost:8000/docs

## Эндпоинты

| Метод и путь | Операция | Действие |
|---|---|---|
| POST /users | Create | регистрация пользователя |
| GET /users | Read | список пользователей |
| GET /users/{id} | Read | получить пользователя |
| POST /dialogues | Create | создать диалог |
| GET /dialogues?user_id= | Read | диалоги пользователя |
| PATCH /dialogues/{id} | Update | переименовать / архивировать |
| DELETE /dialogues/{id} | Delete | удалить диалог (каскадно сообщения) |
| POST /dialogues/{id}/messages | Create | добавить сообщение |
| GET /dialogues/{id}/messages | Read | сообщения диалога |
| GET /analytics/top-models | Read | топ моделей (через функцию БД fn_top_models) |

Аналитический эндпоинт `top-models` не дублирует логику в Python, а вызывает
серверную функцию `fn_top_models`, созданную в `sql/04_functions.sql`.

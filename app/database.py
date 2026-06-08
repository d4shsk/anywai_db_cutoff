"""Подключение к БД через SQLAlchemy."""
from __future__ import annotations

import os

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

# Строка подключения берётся из переменной окружения DATABASE_URL.
# Пример: postgresql+psycopg://postgres:postgres@localhost:5432/postgres
DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql+psycopg://postgres:postgres@localhost:5432/postgres",
)

engine = create_engine(DATABASE_URL, echo=False, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)


class Base(DeclarativeBase):
    """Базовый класс для ORM-моделей."""


def get_db():
    """FastAPI-зависимость: открывает сессию на время запроса."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

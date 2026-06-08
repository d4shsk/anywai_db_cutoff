"""ORM-модели, отражающие схему из sql/01_schema.sql."""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import (
    BigInteger, Boolean, CheckConstraint, ForeignKey, Integer,
    SmallInteger, String, Text, func,
)
from sqlalchemy.dialects.postgresql import JSONB, TIMESTAMP
from sqlalchemy.orm import Mapped, mapped_column, relationship

from database import Base


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    telegram_id: Mapped[int] = mapped_column(BigInteger, unique=True, nullable=False)
    username: Mapped[str | None] = mapped_column(String(64))
    first_name: Mapped[str | None] = mapped_column(String(128))
    last_name: Mapped[str | None] = mapped_column(String(128))
    language_code: Mapped[str] = mapped_column(String(8), default="ru", nullable=False)
    registered_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), server_default=func.now())
    last_seen_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), server_default=func.now())

    dialogues: Mapped[list["Dialogue"]] = relationship(back_populates="user", cascade="all, delete-orphan")


class LLMProvider(Base):
    __tablename__ = "llm_providers"

    id: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    code: Mapped[str] = mapped_column(String(32), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(64), nullable=False)

    models: Mapped[list["LLMModel"]] = relationship(back_populates="provider")


class LLMModel(Base):
    __tablename__ = "llm_models"

    id: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    provider_id: Mapped[int] = mapped_column(ForeignKey("llm_providers.id"), nullable=False)
    code: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(64), nullable=False)
    family: Mapped[str] = mapped_column(String(32), nullable=False)
    is_premium: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    provider: Mapped["LLMProvider"] = relationship(back_populates="models")


class Dialogue(Base):
    __tablename__ = "dialogues"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    title: Mapped[str] = mapped_column(String(255), default="Новый диалог", nullable=False)
    created_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), server_default=func.now())
    is_archived: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    user: Mapped["User"] = relationship(back_populates="dialogues")
    messages: Mapped[list["Message"]] = relationship(back_populates="dialogue", cascade="all, delete-orphan")


class Message(Base):
    __tablename__ = "messages"
    __table_args__ = (
        CheckConstraint("role IN ('user','assistant','system')", name="chk_messages_role_known"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    dialogue_id: Mapped[int] = mapped_column(ForeignKey("dialogues.id", ondelete="CASCADE"), nullable=False)
    role: Mapped[str] = mapped_column(String(16), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    model_id: Mapped[int | None] = mapped_column(ForeignKey("llm_models.id"))
    tokens_in: Mapped[int | None] = mapped_column(Integer)
    tokens_out: Mapped[int | None] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), server_default=func.now())

    dialogue: Mapped["Dialogue"] = relationship(back_populates="messages")


class EventKind(Base):
    __tablename__ = "event_kinds"

    id: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    code: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    description: Mapped[str] = mapped_column(String(255), nullable=False)


class AnalyticsEvent(Base):
    __tablename__ = "analytics_events"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    dialogue_id: Mapped[int | None] = mapped_column(ForeignKey("dialogues.id", ondelete="SET NULL"))
    event_kind_id: Mapped[int] = mapped_column(ForeignKey("event_kinds.id"), nullable=False)
    source: Mapped[str] = mapped_column(String(32), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(TIMESTAMP(timezone=True), server_default=func.now())
    properties_json: Mapped[dict] = mapped_column(JSONB, default=dict)

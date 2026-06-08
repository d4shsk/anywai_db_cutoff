"""Pydantic-схемы запросов и ответов."""
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


# ── users ────────────────────────────────────────────────────────────────
class UserCreate(BaseModel):
    telegram_id: int
    username: str | None = None
    first_name: str | None = None
    last_name: str | None = None
    language_code: str = "ru"


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    telegram_id: int
    username: str | None
    first_name: str | None
    last_name: str | None
    language_code: str
    registered_at: datetime
    last_seen_at: datetime


# ── dialogues ──────────────────────────────────────────────────────────────
class DialogueCreate(BaseModel):
    user_id: int
    title: str = "Новый диалог"


class DialogueUpdate(BaseModel):
    title: str | None = None
    is_archived: bool | None = None


class DialogueOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    user_id: int
    title: str
    created_at: datetime
    updated_at: datetime
    is_archived: bool


# ── messages ────────────────────────────────────────────────────────────────
class MessageCreate(BaseModel):
    role: str = Field(pattern="^(user|assistant|system)$")
    content: str = Field(min_length=1)
    model_id: int | None = None
    tokens_in: int | None = None
    tokens_out: int | None = None


class MessageOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    dialogue_id: int
    role: str
    content: str
    model_id: int | None
    tokens_in: int | None
    tokens_out: int | None
    created_at: datetime


# ── analytics ────────────────────────────────────────────────────────────────
class TopModelOut(BaseModel):
    model_code: str
    display_name: str
    family: str
    usage_count: int

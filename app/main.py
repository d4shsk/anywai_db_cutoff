"""
CRUD REST API над БД истории диалогов AI-чат-сервиса.
Запуск:  uvicorn main:app --reload
Документация Swagger:  http://localhost:8000/docs

Приложение использует уже созданную схему (sql/01_schema.sql ... 06_seed.sql).
Аналитический эндпоинт переиспользует функцию БД fn_top_models.
"""
from __future__ import annotations

from datetime import datetime

from fastapi import Depends, FastAPI, HTTPException
from sqlalchemy import text
from sqlalchemy.orm import Session

from database import get_db
import models
import schemas

app = FastAPI(title="anywai DB cutoff — CRUD API", version="1.0.0")


# ── users ────────────────────────────────────────────────────────────────
@app.post("/users", response_model=schemas.UserOut, status_code=201, tags=["users"])
def create_user(payload: schemas.UserCreate, db: Session = Depends(get_db)):
    user = models.User(**payload.model_dump())
    db.add(user)
    try:
        db.commit()
    except Exception as exc:  # нарушение UNIQUE telegram_id и т.п.
        db.rollback()
        raise HTTPException(status_code=409, detail=str(exc.__cause__ or exc)) from exc
    db.refresh(user)
    return user


@app.get("/users", response_model=list[schemas.UserOut], tags=["users"])
def list_users(limit: int = 50, offset: int = 0, db: Session = Depends(get_db)):
    return db.query(models.User).order_by(models.User.id).offset(offset).limit(limit).all()


@app.get("/users/{user_id}", response_model=schemas.UserOut, tags=["users"])
def get_user(user_id: int, db: Session = Depends(get_db)):
    user = db.get(models.User, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="user not found")
    return user


# ── dialogues ──────────────────────────────────────────────────────────────
@app.post("/dialogues", response_model=schemas.DialogueOut, status_code=201, tags=["dialogues"])
def create_dialogue(payload: schemas.DialogueCreate, db: Session = Depends(get_db)):
    if not db.get(models.User, payload.user_id):
        raise HTTPException(status_code=404, detail="user not found")
    dialogue = models.Dialogue(**payload.model_dump())
    db.add(dialogue)
    db.commit()
    db.refresh(dialogue)
    return dialogue


@app.get("/dialogues", response_model=list[schemas.DialogueOut], tags=["dialogues"])
def list_dialogues(user_id: int, include_archived: bool = False, db: Session = Depends(get_db)):
    q = db.query(models.Dialogue).filter(models.Dialogue.user_id == user_id)
    if not include_archived:
        q = q.filter(models.Dialogue.is_archived.is_(False))
    return q.order_by(models.Dialogue.updated_at.desc()).all()


@app.patch("/dialogues/{dialogue_id}", response_model=schemas.DialogueOut, tags=["dialogues"])
def update_dialogue(dialogue_id: int, payload: schemas.DialogueUpdate, db: Session = Depends(get_db)):
    dialogue = db.get(models.Dialogue, dialogue_id)
    if not dialogue:
        raise HTTPException(status_code=404, detail="dialogue not found")
    data = payload.model_dump(exclude_unset=True)
    for key, value in data.items():
        setattr(dialogue, key, value)
    db.commit()
    db.refresh(dialogue)
    return dialogue


@app.delete("/dialogues/{dialogue_id}", status_code=204, tags=["dialogues"])
def delete_dialogue(dialogue_id: int, db: Session = Depends(get_db)):
    dialogue = db.get(models.Dialogue, dialogue_id)
    if not dialogue:
        raise HTTPException(status_code=404, detail="dialogue not found")
    db.delete(dialogue)  # messages удалятся каскадно (FK ON DELETE CASCADE)
    db.commit()


# ── messages ────────────────────────────────────────────────────────────────
@app.post("/dialogues/{dialogue_id}/messages", response_model=schemas.MessageOut,
          status_code=201, tags=["messages"])
def add_message(dialogue_id: int, payload: schemas.MessageCreate, db: Session = Depends(get_db)):
    if not db.get(models.Dialogue, dialogue_id):
        raise HTTPException(status_code=404, detail="dialogue not found")
    # Бизнес-правило: у assistant обязательна модель, у user/system — запрещена.
    if payload.role == "assistant" and payload.model_id is None:
        raise HTTPException(status_code=422, detail="assistant message requires model_id")
    if payload.role != "assistant" and payload.model_id is not None:
        raise HTTPException(status_code=422, detail="only assistant messages may have model_id")
    message = models.Message(dialogue_id=dialogue_id, **payload.model_dump())
    db.add(message)
    db.commit()
    db.refresh(message)
    return message


@app.get("/dialogues/{dialogue_id}/messages", response_model=list[schemas.MessageOut], tags=["messages"])
def list_messages(dialogue_id: int, limit: int = 100, offset: int = 0, db: Session = Depends(get_db)):
    if not db.get(models.Dialogue, dialogue_id):
        raise HTTPException(status_code=404, detail="dialogue not found")
    return (
        db.query(models.Message)
        .filter(models.Message.dialogue_id == dialogue_id)
        .order_by(models.Message.created_at, models.Message.id)
        .offset(offset).limit(limit).all()
    )


# ── analytics ────────────────────────────────────────────────────────────────
@app.get("/analytics/top-models", response_model=list[schemas.TopModelOut], tags=["analytics"])
def top_models(days: int = 30, limit: int = 10, db: Session = Depends(get_db)):
    """Переиспользует функцию БД fn_top_models(from, to, limit)."""
    rows = db.execute(
        text("SELECT * FROM fn_top_models(NOW() - make_interval(days => :days), NOW(), :limit)"),
        {"days": days, "limit": limit},
    ).mappings().all()
    return [schemas.TopModelOut(**row) for row in rows]


@app.get("/", tags=["meta"])
def root():
    return {"service": "anywai DB cutoff CRUD API", "docs": "/docs", "time": datetime.utcnow().isoformat()}

# -*- coding: utf-8 -*-
"""
Генерация ER-диаграммы (стиль IDEF1x / «таблица с атрибутами») в er_diagram.png.
Запуск: python gen_er_diagram.py
"""
from __future__ import annotations

from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "er_diagram.png"

HEADER_FILL = "#4472C4"
PK_FILL = "#D9E2F3"
BODY_FILL = "#FFFFFF"
EDGE = "#2F5496"
LINE_H = 0.34
TITLE_H = 0.42

# Сущности: имя -> (x, y верхнего левого угла, ширина, [(текст, is_pk, is_fk)])
ENTITIES = {
    "llm_providers": (0.3, 10.2, 3.0, [
        ("PK  id", True, False),
        ("code (UQ)", False, False),
        ("display_name", False, False),
    ]),
    "llm_models": (0.3, 7.7, 3.2, [
        ("PK  id", True, False),
        ("FK  provider_id", False, True),
        ("code (UQ)", False, False),
        ("family", False, False),
        ("is_premium", False, False),
    ]),
    "users": (5.2, 10.4, 3.2, [
        ("PK  id", True, False),
        ("telegram_id (UQ)", False, False),
        ("username", False, False),
        ("language_code", False, False),
        ("last_seen_at", False, False),
    ]),
    "dialogues": (5.2, 7.0, 3.2, [
        ("PK  id", True, False),
        ("FK  user_id", False, True),
        ("title", False, False),
        ("updated_at", False, False),
        ("is_archived", False, False),
    ]),
    "messages": (5.2, 3.4, 3.4, [
        ("PK  id", True, False),
        ("FK  dialogue_id", False, True),
        ("FK  model_id", False, True),
        ("role", False, False),
        ("content", False, False),
        ("tokens_in / out", False, False),
    ]),
    "attachments": (9.9, 3.4, 3.2, [
        ("PK  id", True, False),
        ("FK  message_id", False, True),
        ("kind", False, False),
        ("file_name", False, False),
        ("sha256", False, False),
    ]),
    "dialogue_summaries": (0.3, 3.6, 3.6, [
        ("PK FK  dialogue_id", True, True),
        ("summary", False, False),
        ("FK  until_message_id", False, True),
        ("updated_at", False, False),
    ]),
    "event_kinds": (9.9, 10.4, 3.2, [
        ("PK  id", True, False),
        ("code (UQ)", False, False),
        ("description", False, False),
    ]),
    "analytics_events": (9.9, 6.8, 3.4, [
        ("PK  id", True, False),
        ("FK  user_id", False, True),
        ("FK  dialogue_id", False, True),
        ("FK  event_kind_id", False, True),
        ("source", False, False),
        ("properties_json", False, False),
    ]),
}

# Связи: (родитель, потомок, подпись)
RELATIONS = [
    ("llm_providers", "llm_models", "1:N"),
    ("llm_models", "messages", "1:N"),
    ("users", "dialogues", "1:N"),
    ("dialogues", "messages", "1:N"),
    ("messages", "attachments", "1:N"),
    ("dialogues", "dialogue_summaries", "1:1"),
    ("messages", "dialogue_summaries", "1:N"),
    ("event_kinds", "analytics_events", "1:N"),
    ("users", "analytics_events", "1:N"),
    ("dialogues", "analytics_events", "1:N"),
]


def box_height(rows: int) -> float:
    return TITLE_H + rows * LINE_H


def entity_rect(name):
    x, y, w, attrs = ENTITIES[name]
    h = box_height(len(attrs))
    return x, y, w, h


def anchor(name, side):
    x, y, w, h = entity_rect(name)
    cx, cy = x + w / 2, y - h / 2
    if side == "top":
        return cx, y
    if side == "bottom":
        return cx, y - h
    if side == "left":
        return x, cy
    if side == "right":
        return x + w, cy
    return cx, cy


def draw_entity(ax, name):
    x, y, w, attrs = ENTITIES[name]
    h = box_height(len(attrs))
    # тело
    ax.add_patch(FancyBboxPatch(
        (x, y - h), w, h, boxstyle="round,pad=0.02,rounding_size=0.06",
        linewidth=1.4, edgecolor=EDGE, facecolor=BODY_FILL, zorder=3))
    # заголовок
    ax.add_patch(FancyBboxPatch(
        (x, y - TITLE_H), w, TITLE_H, boxstyle="round,pad=0.02,rounding_size=0.06",
        linewidth=1.4, edgecolor=EDGE, facecolor=HEADER_FILL, zorder=4))
    ax.text(x + w / 2, y - TITLE_H / 2, name, ha="center", va="center",
            fontsize=10.5, fontweight="bold", color="white", zorder=5)
    # атрибуты
    for i, (txt, is_pk, is_fk) in enumerate(attrs):
        ry = y - TITLE_H - i * LINE_H
        if is_pk:
            ax.add_patch(plt.Rectangle((x, ry - LINE_H), w, LINE_H,
                         facecolor=PK_FILL, edgecolor="none", zorder=3.5))
        ax.text(x + 0.12, ry - LINE_H / 2, txt, ha="left", va="center",
                fontsize=8.6, color="#1a1a1a", zorder=5,
                fontweight="bold" if is_pk else "normal")
        ax.plot([x, x + w], [ry - LINE_H, ry - LINE_H], color="#C9C9C9",
                linewidth=0.5, zorder=3.6)


def best_sides(p, c):
    """Выбрать стороны выхода/входа по взаимному расположению."""
    px, py, pw, ph = entity_rect(p)
    cx, cy, cw, ch = entity_rect(c)
    pcx, pcy = px + pw / 2, py - ph / 2
    ccx, ccy = cx + cw / 2, cy - ch / 2
    dx, dy = ccx - pcx, ccy - pcy
    if abs(dy) >= abs(dx):
        return ("bottom", "top") if dy < 0 else ("top", "bottom")
    return ("right", "left") if dx > 0 else ("left", "right")


def draw_relation(ax, p, c, label):
    ps, cs = best_sides(p, c)
    x1, y1 = anchor(p, ps)
    x2, y2 = anchor(c, cs)
    arrow = FancyArrowPatch(
        (x1, y1), (x2, y2),
        connectionstyle="arc3,rad=0.06",
        arrowstyle="-|>", mutation_scale=14,
        linewidth=1.3, color="#7F7F7F", zorder=2)
    ax.add_patch(arrow)
    mx, my = (x1 + x2) / 2, (y1 + y2) / 2
    ax.text(mx, my, label, ha="center", va="center", fontsize=8,
            color="#444", zorder=6,
            bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.85))


def main():
    fig, ax = plt.subplots(figsize=(13.5, 9.0), dpi=200)
    ax.set_xlim(0, 13.6)
    ax.set_ylim(0, 11.2)
    ax.axis("off")

    for p, c, lbl in RELATIONS:
        draw_relation(ax, p, c, lbl)
    for name in ENTITIES:
        draw_entity(ax, name)

    ax.set_title("ER-диаграмма БД истории диалогов и аналитики AI-чат-сервиса",
                 fontsize=13, fontweight="bold", pad=10)
    fig.tight_layout()
    fig.savefig(OUT, bbox_inches="tight", facecolor="white")
    print(f"Saved: {OUT}")


if __name__ == "__main__":
    main()

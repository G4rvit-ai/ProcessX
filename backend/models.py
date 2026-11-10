"""models.py - the tables of the database (Phase 4, step 4).

A model is a Python class that stands for one table. Each attribute is a column, and each object of the
class is one row. Step 4 has one table: every comparison the backend has run (POST /baselines/<name>/compare).

The columns you may want to search or sort by later (when, which baseline, the score) are columns of their own.
The whole answer that was given is kept as well, as JSON, so that nothing is lost.
"""
from datetime import datetime, timezone

from sqlalchemy import JSON, DateTime, String
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


def now_utc():
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    """Every model is a subclass of this one, so that SQLAlchemy can find all the tables."""


class Comparison(Base):
    """One comparison of one run with a baseline."""
    __tablename__ = "comparisons"

    id: Mapped[int] = mapped_column(primary_key=True)                   # 1, 2, 3 ... given by the database
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now_utc, index=True)   # UTC
    baseline_name: Mapped[str] = mapped_column(String(200), index=True)
    run: Mapped[str] = mapped_column(String(300))                       # the folder name inside traces/runs/
    score: Mapped[int]
    level: Mapped[str] = mapped_column(String(30))
    matches: Mapped[bool]                                               # every feature inside the baseline's range
    features_compared: Mapped[int]
    outside_range: Mapped[int]
    result: Mapped[dict] = mapped_column(JSON)                          # the whole answer, as it was given

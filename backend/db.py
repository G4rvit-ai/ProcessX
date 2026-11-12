"""db.py - the connection to the database, saving a comparison, and reading the history back (Phase 4, steps 4-5).

Which database is set by one text, the database URL:
    sqlite:////full/path/processx.db                    a single file (the default: processx.db in the project folder)
    postgresql+psycopg://user:password@host/dbname      PostgreSQL (later; it needs its driver: pip install psycopg[binary])
Set the environment variable PROCESSX_DATABASE_URL to use another one. For SQLite use a full path.
"""
import logging
import os
from datetime import timezone

from sqlalchemy import create_engine, func, select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import sessionmaker

from backend import store
from backend.models import Base, Comparison

log = logging.getLogger("processx.db")

URL = os.environ.get("PROCESSX_DATABASE_URL") or f"sqlite:///{store.PROJECT_DIR / 'processx.db'}"

# SQLite insists that the thread that opened a connection is the one that uses it; the web server uses several threads.
engine = create_engine(URL, connect_args={"check_same_thread": False} if URL.startswith("sqlite") else {})

# A session is one conversation with the database: add rows, then commit (save) them.
Session = sessionmaker(engine, expire_on_commit=False)

# The biggest number that fits in the id column on every database. A bigger id cannot exist, so asking for one is not an error.
MAX_ID = 2**31 - 1


class Unavailable(Exception):
    """The database could not be read. The details are in the server's log."""


def create_tables():
    """Make the tables that are missing. Tables and rows that are already there are left alone."""
    Base.metadata.create_all(engine)


def save_comparison(result):
    """Save one comparison (the dictionary POST /baselines/<name>/compare answers with). Returns its id.

    If the database refuses, the comparison has already been run and its answer is still worth giving,
    so this logs the problem and returns None instead of raising.
    """
    row = Comparison(
        baseline_name=result["baseline"], run=result["run"], score=result["score"], level=result["level"],
        matches=result["matches"], features_compared=result["features_compared"],
        outside_range=result["outside_range"], result=result,
    )
    try:
        with Session() as session:
            session.add(row)
            session.commit()
            return row.id
    except SQLAlchemyError as problem:
        log.warning("could not save the comparison of baseline %s: %s", result["baseline"], problem)
        return None


def utc_text(moment):
    """A time as text that says it is UTC, like 2026-11-11T10:28:04.013441+00:00.

    SQLite gives the times back without a zone (they were saved as UTC); PostgreSQL gives them back with one.
    """
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc).isoformat()


# The columns of a comparison except its long "result": enough for a list.
SUMMARY_COLUMNS = (Comparison.id, Comparison.created_at, Comparison.baseline_name, Comparison.run, Comparison.score,
                   Comparison.level, Comparison.matches, Comparison.features_compared, Comparison.outside_range)


def list_comparisons(baseline=None, min_score=None, limit=20, offset=0):
    """The saved comparisons, newest first. Returns (how many match, the page asked for).

    baseline and min_score narrow it down (None = no narrowing). Newest first means the biggest id first:
    ids only ever go up. limit and offset cut out one page: skip the newest `offset`, then take `limit`.
    Raises Unavailable if the database cannot be read.
    """
    if baseline is not None and "\x00" in baseline:
        return 0, []        # no baseline has a NUL character in its name, and PostgreSQL refuses to even look for one
    conditions = []
    if baseline is not None:
        conditions.append(Comparison.baseline_name == baseline)       # the name must be exactly this one
    if min_score is not None:
        conditions.append(Comparison.score >= min_score)
    try:
        with Session() as session:
            total = session.scalar(select(func.count()).select_from(Comparison).where(*conditions))
            page = session.execute(
                select(*SUMMARY_COLUMNS).where(*conditions).order_by(Comparison.id.desc()).limit(limit).offset(offset)
            ).all()
    except SQLAlchemyError as problem:
        log.warning("could not read the comparisons: %s", problem)
        raise Unavailable from None
    return total, [
        {"id": r.id, "created_at": utc_text(r.created_at), "baseline": r.baseline_name, "run": r.run, "score": r.score,
         "level": r.level, "matches": r.matches, "features_compared": r.features_compared, "outside_range": r.outside_range}
        for r in page
    ]


def get_comparison(comparison_id):
    """One saved comparison in full: exactly the answer it gave when it ran, plus its id and when it was made.

    Returns None if there is no comparison with that id. Raises Unavailable if the database cannot be read.
    """
    if not 1 <= comparison_id <= MAX_ID:
        return None
    try:
        with Session() as session:
            row = session.get(Comparison, comparison_id)
    except SQLAlchemyError as problem:
        log.warning("could not read comparison %s: %s", comparison_id, problem)
        raise Unavailable from None
    if row is None:
        return None
    return {**row.result, "id": row.id, "created_at": utc_text(row.created_at)}

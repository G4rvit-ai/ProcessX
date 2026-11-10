"""db.py - the connection to the database, and saving a comparison (Phase 4, step 4).

Which database is set by one text, the database URL:
    sqlite:////full/path/processx.db                    a single file (the default: processx.db in the project folder)
    postgresql+psycopg://user:password@host/dbname      PostgreSQL (later; it needs its driver: pip install psycopg[binary])
Set the environment variable PROCESSX_DATABASE_URL to use another one. For SQLite use a full path.
"""
import logging
import os

from sqlalchemy import create_engine
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

"""main.py - the ProcessX backend (Phase 4, step 1).

A small web server that other programs (soon: the dashboard) can talk to over HTTP.
So far it can only say whether it is alive and what it can see on this computer.

Run it from the project folder (~/processx):
    uvicorn backend.main:app --reload

Then open http://127.0.0.1:8000/health (the data) or http://127.0.0.1:8000/docs (a page that
lists every endpoint and lets you try them).
"""
import shutil
from pathlib import Path

from fastapi import FastAPI

PROJECT_DIR = Path(__file__).resolve().parent.parent     # ~/processx, wherever the server was started from
BASELINES_DIR = PROJECT_DIR / "baselines"

app = FastAPI(title="ProcessX", version="0.1.0",
              description="System call behavior analyzer: baselines, comparisons and scores.")


@app.get("/health")
def health():
    """Is the server alive, is strace installed, and how many baselines are saved?"""
    return {
        "status": "ok",
        "strace": shutil.which("strace") is not None,
        "baselines": len(list(BASELINES_DIR.glob("*.json"))) if BASELINES_DIR.is_dir() else 0,
    }

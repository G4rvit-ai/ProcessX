"""main.py - the ProcessX backend (Phase 4).

A small web server that other programs (soon: the dashboard) can talk to over HTTP.
Step 1: /health.  Step 2: /baselines and /baselines/<name>, read-only.

Run it from the project folder (~/processx):
    uvicorn backend.main:app --reload

Then open http://127.0.0.1:8000/docs (a page that lists every endpoint and lets you try them).
"""
import shutil

from fastapi import FastAPI, HTTPException

from backend import store

app = FastAPI(title="ProcessX", version="0.2.0",
              description="System call behavior analyzer: baselines, comparisons and scores.")


@app.get("/health")
def health():
    """Is the server alive, is strace installed, and how many baseline files are saved?"""
    return {
        "status": "ok",
        "strace": shutil.which("strace") is not None,
        "baselines": len(list(store.BASELINES_DIR.glob("*.json"))) if store.BASELINES_DIR.is_dir() else 0,
    }


@app.get("/baselines")
def list_baselines():
    """Every saved baseline in short, and the files that cannot be used (and why)."""
    good, bad = store.list_baselines()
    return {"count": len(good), "baselines": good, "unreadable": bad}


@app.get("/baselines/{name}")
def get_baseline(name: str):
    """One baseline in full: for every feature, the lowest and highest value seen in its normal runs."""
    shown = name if len(name) <= 80 else name[:77] + "..."      # never echo back a huge name
    try:
        return store.get_baseline(name)
    except store.NotFound:
        raise HTTPException(status_code=404, detail=f"No baseline named '{shown}'.") from None
    except store.Unreadable as problem:
        raise HTTPException(status_code=500, detail=f"The file for baseline '{shown}' cannot be used: {problem}") from None

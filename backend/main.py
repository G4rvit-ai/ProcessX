"""main.py - the ProcessX backend (Phase 4).

A small web server that other programs (soon: the dashboard) can talk to over HTTP.
Step 1: /health.  Step 2: /baselines and /baselines/<name>.  Step 3: POST /baselines/<name>/compare.

Run it from the project folder (~/processx):
    uvicorn backend.main:app --reload

Then open http://127.0.0.1:8000/docs (a page that lists every endpoint and lets you try them).
"""
import shutil

from fastapi import Depends, FastAPI, HTTPException, Request
from starlette.middleware.trustedhost import TrustedHostMiddleware

from backend import runs, store

app = FastAPI(title="ProcessX", version="0.3.0",
              description="System call behavior analyzer: baselines, comparisons and scores.")

# Only requests addressed to this computer are answered. A request for any other name (a web page that tricks
# the browser into talking to this server under its own name, called DNS rebinding) is refused with 400.
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost"])


def only_from_this_page(request: Request):
    """Refuse a request that a web page from another site made the browser send (a browser says where it came from).

    Without this, any page you open in your browser could press "run" on this server: the address 127.0.0.1 is
    reachable from your own browser, whatever page it is showing. curl sends no Origin, so it is not affected.
    """
    origin = request.headers.get("origin")
    if origin is not None and origin != f"http://{request.headers.get('host', '')}":
        raise HTTPException(status_code=403, detail="This request came from another web page, so it was refused.")


def shorten(name):
    """A name for an error message: never echo back a huge one."""
    return name if len(name) <= 80 else name[:77] + "..."


def not_found(name):
    return HTTPException(status_code=404, detail=f"No baseline named '{shorten(name)}'.")


def unusable(name, problem):
    return HTTPException(status_code=500, detail=f"The file for baseline '{shorten(name)}' cannot be used: {problem}")


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
    try:
        return store.get_baseline(name)
    except store.NotFound:
        raise not_found(name) from None
    except store.Unreadable as problem:
        raise unusable(name, problem) from None


@app.post("/baselines/{name}/compare", dependencies=[Depends(only_from_this_page)])
def compare_baseline(name: str):
    """Run the command saved in this baseline once, compare the run with the baseline, and return the score and the reasons.

    Only the saved command is ever run; nothing in the request can change it. One comparison at a time.
    A request that another web page made your browser send is refused (403).
    """
    try:
        return runs.compare_baseline(name)
    except store.NotFound:
        raise not_found(name) from None
    except store.Unreadable as problem:
        raise unusable(name, problem) from None
    except runs.Busy:
        raise HTTPException(status_code=409, detail="Another comparison is already running. Try again in a moment.") from None
    except runs.RunFailed as failed:
        raise HTTPException(status_code=failed.status, detail=f"Could not run baseline '{shorten(name)}': {failed}") from None

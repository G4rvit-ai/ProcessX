"""main.py - the ProcessX backend and integrated dashboard (Phases 4 and 6).

A small local-only web server for the dashboard and HTTP API.
Step 1: /health.  Step 2: /baselines and /baselines/<name>.  Step 3: POST /baselines/<name>/compare.
Step 4: every comparison is saved in a database (backend/db.py), and the answer carries its id.
Step 5: GET /comparisons and GET /comparisons/<id> give the saved history back.
Phase 6: serve the production dashboard build from / and /assets.

Run it from the project folder (~/processx):
    ./start_processx.sh

Then open http://127.0.0.1:8000 (dashboard) or /docs (API documentation).
"""
import shutil
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.trustedhost import TrustedHostMiddleware

from backend import db, runs, store


@asynccontextmanager
async def lifespan(app):
    """What happens when the server starts (before the yield) and when it stops (after it)."""
    db.create_tables()      # makes the missing tables; if the database cannot be opened, the server stops here and says why
    yield


app = FastAPI(title="ProcessX", version="0.5.0", lifespan=lifespan,
              description="System call behavior analyzer: baselines, comparisons and scores.")

# Only requests addressed to this computer are answered. A request for any other name (a web page that tricks
# the browser into talking to this server under its own name, called DNS rebinding) is refused with 400.
app.add_middleware(
    TrustedHostMiddleware,
    allowed_hosts=["127.0.0.1", "localhost", "processx.localhost"],
)

DASHBOARD_DIST = Path(__file__).resolve().parent.parent / "dashboard" / "dist"
app.mount(
    "/assets",
    StaticFiles(directory=DASHBOARD_DIST / "assets", check_dir=False),
    name="dashboard-assets",
)


@app.get("/", include_in_schema=False)
def dashboard():
    """Serve the production dashboard build from the same local-only server as the API."""
    index = DASHBOARD_DIST / "index.html"
    if not index.is_file():
        raise HTTPException(
            status_code=503,
            detail="The dashboard has not been built. Run: npm --prefix dashboard run build",
        )
    return FileResponse(index)


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


def history_unreadable():
    return HTTPException(status_code=503, detail="The database could not be read (the server's terminal says why).")


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
    The comparison is saved in the database; "id" is its number there (null if it could not be saved).
    """
    try:
        result = runs.compare_baseline(name)
    except store.NotFound:
        raise not_found(name) from None
    except store.Unreadable as problem:
        raise unusable(name, problem) from None
    except runs.Busy:
        raise HTTPException(status_code=409, detail="Another comparison is already running. Try again in a moment.") from None
    except runs.RunFailed as failed:
        raise HTTPException(status_code=failed.status, detail=f"Could not run baseline '{shorten(name)}': {failed}") from None
    result["id"] = db.save_comparison(result)
    if result["id"] is None:
        result["warnings"].append("This comparison could not be saved in the database (the server's terminal says why).")
    return result


@app.get("/comparisons")
def list_comparisons(
    baseline: str | None = Query(None, description="only the comparisons of the baseline with exactly this name"),
    min_score: int | None = Query(None, ge=0, le=100, description="only the comparisons with this score or more"),
    limit: int = Query(20, ge=1, le=100, description="how many comparisons to give (the size of a page)"),
    offset: int = Query(0, ge=0, le=10_000_000, description="how many of the newest ones to skip (to get the next page)"),
):
    """The saved comparisons, newest first, without their long details (GET /comparisons/<id> has those).

    "total" is how many comparisons match the filters, whatever the page size, so a page can tell how many there are.
    Read-only: nothing here can change the history.
    """
    try:
        total, page = db.list_comparisons(baseline, min_score, limit, offset)
    except db.Unavailable:
        raise history_unreadable() from None
    return {"total": total, "limit": limit, "offset": offset, "comparisons": page}


@app.get("/comparisons/{comparison_id}")
def get_comparison(comparison_id: int):
    """One saved comparison in full: exactly the answer it gave when it ran (score, findings, differences...), plus its id and when."""
    try:
        found = db.get_comparison(comparison_id)
    except db.Unavailable:
        raise history_unreadable() from None
    if found is None:
        raise HTTPException(status_code=404, detail=f"No comparison with id {shorten(str(comparison_id))}.")
    return found

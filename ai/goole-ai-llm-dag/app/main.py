from pathlib import Path
import logging

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.dag import run_dag
from app.models import DAGRequest, DAGResponse


logging.basicConfig(level=logging.INFO)


BASE_DIR = Path(__file__).resolve().parent.parent

templates = Jinja2Templates(
    directory=str(BASE_DIR / "templates")
)


app = FastAPI(
    title="Gemini LLM DAG",
    version="1.0.0",
)


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={},
    )


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/dag", response_model=DAGResponse)
def dag(request: DAGRequest):
    print(f"[API] Received DAG request: {request.prompt}")

    try:
        result = run_dag(request.prompt)

        print("[API] DAG request completed successfully")

        return result

    except Exception as exc:
        print(f"[API] DAG failed: {exc}")

        raise HTTPException(
            status_code=503,
            detail=str(exc),
        )

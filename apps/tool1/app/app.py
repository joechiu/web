import os
import time
import uuid
import requests
from fastapi import FastAPI, Form
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi import Request
from urllib.parse import urlparse

opt="ok"
opt=""
if opt == "ok":
  API = os.getenv("OK_AZUREML_ENDPOINT_API")
  KEY = os.getenv("OK_AZUREML_ENDPOINT_KEY")
else:
  API = os.getenv("AZUREML_ENDPOINT_API")
  KEY = os.getenv("AZUREML_ENDPOINT_KEY")

EP = urlparse(API).hostname.split(".")[0]

print("API:", API)

app = FastAPI(
    title="OneCX Tool1 Tester",
    description="Simple web interface for testing the Azure ML endpoint.",
    version="1.0.0"
)
templates = Jinja2Templates(directory="templates")


@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "api": EP,
            "result": None
        }
    )

@app.post("/", response_class=HTMLResponse)
def invoke(
    request: Request,
    url: str = Form(...),
    path: str = Form("/")
):
    payload = {
        "jobId": str(uuid.uuid4()),
        "url": url,
        "path": path
    }
    headers = {
        "Authorization": f"Bearer {KEY}",
        "Content-Type": "application/json"
    }

    start_time = time.perf_counter()

    try:
        r = requests.post(
            API,
            headers=headers,
            json=payload,
            timeout=(10,600)
        )
        try:
            result = r.json()
        except Exception:
            result = {
                "status": r.status_code,
                "body": r.text
            }
    except Exception as ex:
        result = {
            "error": str(ex)
        }

    elapsed_seconds = round(time.perf_counter() - start_time, 2)

    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "result": result,
            "url": url,
            "api": EP,
            "path": path,
            "elapsed_seconds": elapsed_seconds
        }
    )

@app.post("/score")
def score(payload: dict):
    headers = {
        "Authorization": f"Bearer {KEY}",
        "Content-Type": "application/json"
    }
    r = requests.post(
        API,
        headers=headers,
        json=payload,
        timeout=(10,600)
    )
    return r.json()



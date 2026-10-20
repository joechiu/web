import os
import json
import time
import httpx

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

# ============================================================
# CONFIGURATION
# ============================================================

TOOL4_ENDPOINT = os.getenv("EP_API")

EP_KEY = os.getenv("EP_KEY")

MODEL_DEPLOYMENT = os.getenv("ML_DEP")

def timediff(t=None):
    if t:
        return round( time.perf_counter() - t, 4 )
    else:
        return time.perf_counter()

t1 = timediff()

# ============================================================
# FASTAPI APPLICATION
# ============================================================

app = FastAPI(
    title="Tool4 Validation Web App",
    description="Web interface for Tool4 validation",
    version="1.0.0",
)


# ============================================================
# STATIC FILES
# ============================================================

app.mount(
    "/static",
    StaticFiles(directory="static"),
    name="static",
)


# ============================================================
# TEMPLATES
# ============================================================

templates = Jinja2Templates(
    directory="templates"
)


# ============================================================
# HEALTH CHECK
# ============================================================

@app.get("/health")
async def health():
    return {
        "status": "ok",
        "tool4_endpoint": TOOL4_ENDPOINT,
        "model_deployment": MODEL_DEPLOYMENT,
        "ep_key_configured": bool(EP_KEY),
    }


# ============================================================
# HOME PAGE
# ============================================================

@app.get(
    "/",
    response_class=HTMLResponse,
)
async def home(request: Request):

    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
        },
    )


# ============================================================
# TOOL4 VALIDATION
# ============================================================

@app.post("/validate")
async def validate_tool4(request: Request):

    # --------------------------------------------------------
    # Check EP_KEY
    # --------------------------------------------------------

    if not EP_KEY:

        return JSONResponse(
            status_code=500,
            content={
                "detail":
                    "EP_KEY environment variable is not configured."
            },
        )


    # --------------------------------------------------------
    # Read request body
    # --------------------------------------------------------

    try:

        payload = await request.json()

    except Exception as exc:

        return JSONResponse(
            status_code=400,
            content={
                "detail":
                    f"Invalid JSON request: {str(exc)}"
            },
        )


    # --------------------------------------------------------
    # Validate that payload is an object
    # --------------------------------------------------------

    if not isinstance(payload, dict):

        return JSONResponse(
            status_code=400,
            content={
                "detail":
                    "Request body must be a JSON object."
            },
        )


    # --------------------------------------------------------
    # Headers
    #
    # Equivalent to:
    #
    # curl -s -X POST \
    #   "https://.../score" \
    #   -H "Content-Type: application/json" \
    #   -H "Authorization: Bearer $EP_KEY" \
    #   -H "azureml-model-deployment: red" \
    #   -d @jsonfile.json
    # --------------------------------------------------------

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {EP_KEY}",
        "azureml-model-deployment": MODEL_DEPLOYMENT,
    }


    # --------------------------------------------------------
    # Call Tool4 Azure ML endpoint
    # --------------------------------------------------------

    try:

        async with httpx.AsyncClient(
            timeout=httpx.Timeout(
                connect=30.0,
                read=180.0,
                write=30.0,
                pool=30.0,
            )
        ) as client:

            response = await client.post(
                TOOL4_ENDPOINT,
                headers=headers,
                json=payload,
            )


    except httpx.TimeoutException:

        return JSONResponse(
            status_code=504,
            content={
                "detail":
                    "Tool4 endpoint request timed out."
            },
        )


    except httpx.RequestError as exc:

        return JSONResponse(
            status_code=502,
            content={
                "detail":
                    f"Unable to connect to Tool4 endpoint: {str(exc)}"
            },
        )


    # --------------------------------------------------------
    # Process Tool4 response
    # --------------------------------------------------------

    content_type = response.headers.get(
        "content-type",
        ""
    ).lower()


    # --------------------------------------------------------
    # JSON response
    # --------------------------------------------------------

    if "application/json" in content_type:

        try:

            tool4_result = response.json()

        except json.JSONDecodeError:

            return JSONResponse(
                status_code=502,
                content={
                    "detail":
                        "Tool4 returned invalid JSON.",
                    "status_code":
                        response.status_code,
                    "raw_response":
                        response.text,
                },
            )


    # --------------------------------------------------------
    # Non-JSON response
    # --------------------------------------------------------

    else:

        if response.is_error:

            return JSONResponse(
                status_code=502,
                content={
                    "detail":
                        "Tool4 endpoint returned a non-JSON error response.",
                    "status_code":
                        response.status_code,
                    "raw_response":
                        response.text,
                },
            )


        return JSONResponse(
            status_code=200,
            content={
                "tool4_response":
                    response.text
            },
        )


    # --------------------------------------------------------
    # Tool4 HTTP error
    # --------------------------------------------------------

    if response.is_error:

        return JSONResponse(
            status_code=response.status_code,
            content={
                "detail":
                    "Tool4 validation endpoint returned an error.",
                "tool4_status_code":
                    response.status_code,
                "tool4_response":
                    tool4_result,
            },
        )


    # --------------------------------------------------------
    # Successful Tool4 response
    #
    # Return the response as-is.
    #
    # This preserves:
    #
    # decision
    # decision_result
    # validation_output
    # validation_fail_report
    # outcome_trace
    # node_outcomes
    # quality_scores
    # compliance_findings
    # evidence_grounding_findings
    # etc.
    # --------------------------------------------------------

    return JSONResponse(
        status_code=200,
        content=tool4_result,
    )


# ============================================================
# STARTUP INFORMATION
# ============================================================

@app.on_event("startup")
async def startup_event():

    print("")
    print("=" * 70)
    print("Tool4 Validation Web App")
    print("=" * 70)
    print(
        f"Tool4 endpoint : {TOOL4_ENDPOINT}"
    )
    print(
        f"Model deployment: {MODEL_DEPLOYMENT}"
    )
    print(
        f"EP_KEY configured: {bool(EP_KEY)}"
    )
    print("=" * 70)
    print("")



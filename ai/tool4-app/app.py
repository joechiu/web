import json
import time
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates


BASE_DIR = Path(__file__).resolve().parent

INPUTS_DIR = BASE_DIR / "data" / "inputs"
OUTPUTS_DIR = BASE_DIR / "data" / "outputs"


def timediff(t=None):
    if t is not None:
        return round(time.perf_counter() - t, 4)

    return time.perf_counter()


app = FastAPI(
    title="Tool4 Validation Web App",
    description="Web interface for Tool4 validation",
    version="1.0.0",
)


app.mount(
    "/static",
    StaticFiles(directory=str(BASE_DIR / "static")),
    name="static",
)


templates = Jinja2Templates(
    directory=str(BASE_DIR / "templates")
)


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "mode": "local-output",
        "inputs_directory": str(INPUTS_DIR),
        "outputs_directory": str(OUTPUTS_DIR),
    }


@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
        },
    )


def find_matching_output(payload):
    """
    Find the input JSON file whose contents exactly match
    the submitted request payload.

    The matching output uses the same filename under
    data/outputs/.
    """

    if not INPUTS_DIR.exists():
        raise FileNotFoundError(
            f"Input directory does not exist: {INPUTS_DIR}"
        )

    if not OUTPUTS_DIR.exists():
        raise FileNotFoundError(
            f"Output directory does not exist: {OUTPUTS_DIR}"
        )

    for input_file in sorted(INPUTS_DIR.glob("*.json")):

        try:
            with input_file.open(
                "r",
                encoding="utf-8",
            ) as fh:
                input_data = json.load(fh)

        except (OSError, json.JSONDecodeError):
            continue

        if input_data == payload:
            return OUTPUTS_DIR / input_file.name

    return None


@app.get("/inputs")
async def list_inputs():

    if not INPUTS_DIR.exists():
        return JSONResponse(
            status_code=500,
            content={
                "detail": (
                    f"Input directory does not exist: "
                    f"{INPUTS_DIR}"
                )
            },
        )

    files = sorted(
        path.name
        for path in INPUTS_DIR.glob("*.json")
        if path.is_file()
    )

    return {
        "files": files,
    }


@app.get("/inputs/{filename}")
async def get_input(filename: str):
    """
    Return the contents of one input JSON file.

    Only filenames in data/inputs are allowed.
    """

    # Prevent path traversal.
    requested_path = Path(filename)

    if (
        requested_path.name != filename
        or "/" in filename
        or "\\" in filename
        or filename in {".", ".."}
    ):
        return JSONResponse(
            status_code=400,
            content={
                "detail": "Invalid input filename.",
            },
        )

    input_file = INPUTS_DIR / filename

    if not input_file.exists():
        return JSONResponse(
            status_code=404,
            content={
                "detail": "Input file not found.",
                "filename": filename,
            },
        )

    if not input_file.is_file():
        return JSONResponse(
            status_code=400,
            content={
                "detail": "Requested path is not a file.",
                "filename": filename,
            },
        )

    try:
        with input_file.open(
            "r",
            encoding="utf-8",
        ) as fh:
            data = json.load(fh)

    except json.JSONDecodeError as exc:
        return JSONResponse(
            status_code=500,
            content={
                "detail": "Input file contains invalid JSON.",
                "filename": filename,
                "error": str(exc),
            },
        )

    except OSError as exc:
        return JSONResponse(
            status_code=500,
            content={
                "detail": "Unable to read input file.",
                "filename": filename,
                "error": str(exc),
            },
        )

    return data


@app.post("/validate")
async def validate_tool4(request: Request):

    start_time = timediff()

    # ------------------------------------------------------------
    # Read request JSON
    # ------------------------------------------------------------

    try:
        payload = await request.json()

    except Exception as exc:
        return JSONResponse(
            status_code=400,
            content={
                "detail": f"Invalid JSON request: {str(exc)}",
            },
        )

    if not isinstance(payload, dict):
        return JSONResponse(
            status_code=400,
            content={
                "detail": "Request body must be a JSON object.",
            },
        )

    # ------------------------------------------------------------
    # Find matching local output
    # ------------------------------------------------------------

    try:
        output_file = find_matching_output(payload)

    except FileNotFoundError as exc:
        return JSONResponse(
            status_code=500,
            content={
                "detail": str(exc),
            },
        )

    # No matching testcase.
    if output_file is None:
        return JSONResponse(
            status_code=404,
            content={
                "detail": (
                    "No matching test case was found "
                    "in data/inputs."
                ),
            },
        )

    # Matching input exists but output doesn't.
    if not output_file.is_file():
        return JSONResponse(
            status_code=404,
            content={
                "detail": (
                    "Matching input was found, but the "
                    "corresponding output JSON does not exist."
                ),
                "output_file": output_file.name,
            },
        )

    # ------------------------------------------------------------
    # Read local Tool4 result
    # ------------------------------------------------------------

    try:
        with output_file.open(
            "r",
            encoding="utf-8",
        ) as fh:
            tool4_result = json.load(fh)

    except json.JSONDecodeError as exc:
        return JSONResponse(
            status_code=500,
            content={
                "detail": (
                    "The local Tool4 output contains "
                    "invalid JSON."
                ),
                "output_file": output_file.name,
                "error": str(exc),
            },
        )

    except OSError as exc:
        return JSONResponse(
            status_code=500,
            content={
                "detail": (
                    "Unable to read the local Tool4 output."
                ),
                "output_file": output_file.name,
                "error": str(exc),
            },
        )

    # ------------------------------------------------------------
    # Add application execution time
    # ------------------------------------------------------------

    execution_time = timediff(start_time)

    if isinstance(tool4_result, dict):
        tool4_result["app_execution_time"] = execution_time
    else:
        tool4_result = {
            "tool4_response": tool4_result,
            "app_execution_time": execution_time,
        }

    return JSONResponse(
        status_code=200,
        content=tool4_result,
    )


@app.on_event("startup")
async def startup_event():

    print("")
    print("=" * 70)
    print("Tool4 Validation Web App")
    print("=" * 70)
    print("Mode            : local-output")
    print(f"Input directory : {INPUTS_DIR}")
    print(f"Output directory: {OUTPUTS_DIR}")
    print("=" * 70)
    print("")

    input_count = 0

    if INPUTS_DIR.exists():
        input_count = len(
            list(INPUTS_DIR.glob("*.json"))
        )

    output_count = 0

    if OUTPUTS_DIR.exists():
        output_count = len(
            list(OUTPUTS_DIR.glob("*.json"))
        )

    print(f"Input files      : {input_count}")
    print(f"Output files     : {output_count}")
    print("")



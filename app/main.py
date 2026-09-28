from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pathlib import Path

from .analyzer import analyze
from .models import Inventory, MigrationReport

app = FastAPI(title="AL to RHEL Migration Analyzer", version="1.0.0")

BASE_DIR = Path(__file__).resolve().parent
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")

reports: dict[str, MigrationReport] = {}


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse(request, "index.html")


@app.post("/analyze")
async def analyze_upload(
    request: Request,
    file: UploadFile | None = File(None),
    inventory_json: str = Form(""),
    target_os: str = Form("rhel9"),
):
    raw = ""
    if file and file.filename:
        raw = (await file.read()).decode("utf-8")
    elif inventory_json.strip():
        raw = inventory_json.strip()
    else:
        raise HTTPException(status_code=400, detail="No inventory data provided.")

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {e}")

    try:
        inventory = Inventory(**data)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid inventory format: {e}")

    report = analyze(inventory, target_os)
    report.report_id = uuid.uuid4().hex[:12]
    report.generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    reports[report.report_id] = report

    return RedirectResponse(url=f"/report/{report.report_id}", status_code=303)


@app.get("/report/{report_id}", response_class=HTMLResponse)
async def view_report(request: Request, report_id: str):
    report = reports.get(report_id)
    if not report:
        raise HTTPException(status_code=404, detail="Report not found.")
    return templates.TemplateResponse(request, "report.html", {"report": report})


@app.post("/api/analyze", response_class=JSONResponse)
async def api_analyze(
    request: Request,
    file: UploadFile | None = File(None),
    inventory_json: str = Form(""),
    target_os: str = Form("rhel9"),
):
    raw = ""
    if file and file.filename:
        raw = (await file.read()).decode("utf-8")
    elif inventory_json.strip():
        raw = inventory_json.strip()

    if not raw:
        body = await request.body()
        if body:
            raw = body.decode("utf-8")

    if not raw:
        raise HTTPException(status_code=400, detail="No inventory data provided.")

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {e}")

    if "target_os" in data and isinstance(data.get("target_os"), str):
        target_os = data.pop("target_os")

    try:
        inventory = Inventory(**data)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid inventory format: {e}")

    report = analyze(inventory, target_os)
    report.report_id = uuid.uuid4().hex[:12]
    report.generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    return JSONResponse(content=report.model_dump())

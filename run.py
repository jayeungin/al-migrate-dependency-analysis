#!/usr/bin/env python3
import os
import uvicorn

if __name__ == "__main__":
    reload = os.getenv("DEV", "").lower() in ("1", "true")
    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=reload)

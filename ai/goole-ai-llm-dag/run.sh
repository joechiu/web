#!/bin/bash

cd "$(dirname "$0")"

exec uvicorn \
    app.main:app \
    --host 0.0.0.0 \
    --port 8000 \
    --workers 4


FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 libspatialindex-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY pyproject.toml ./

# install CPU-only torch first
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch torchvision \
 && pip install --no-cache-dir -e .

COPY app/ app/

ENV MODEL_DIR=/app/models
ENV CORS_ORIGINS=*

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]

# ---- Build stage ----
FROM python:3.12-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# ---- Runtime stage ----
FROM python:3.12-slim

WORKDIR /app

# Prevents .pyc files being written to disk
# Ensures logs appear immediately in kubectl logs
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Non-root user — matches runAsUser: 1000 in deployment security context
RUN groupadd -g 1000 appgroup && \
    useradd -u 1000 -g appgroup -s /bin/false appuser

COPY --from=builder /install /usr/local

# Copies all app files including vault_db.py if present
COPY . .

USER appuser

EXPOSE 5000

# gthread workers handle DB/IO efficiently
# --preload loads app once then forks workers
# --worker-tmp-dir /tmp required for readOnlyRootFilesystem security context
CMD ["gunicorn", "app:app", "-w", "3", "-k", "gthread", "--threads", "4", "-b", "0.0.0.0:5000", "--preload", "--worker-tmp-dir", "/tmp"]

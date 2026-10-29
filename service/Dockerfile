# syntax=docker/dockerfile:1
FROM python:3.12-slim
WORKDIR /app
COPY service/requirements.lock /app/requirements.txt
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 && rm -rf /var/lib/apt/lists/*
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export PIP_CERT=/run/secrets/proxy_ca; fi; \
    pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home harness && mkdir /data && chown harness /data
COPY --chown=10001:10001 service/main.py /app/service/main.py
COPY --chown=10001:10001 service/web /app/service/web
USER harness
EXPOSE 8080
CMD ["uvicorn", "service.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--workers", "1", "--no-access-log"]

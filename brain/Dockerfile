FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    HA_CONFIG=/config/config.yaml TZ=America/Chicago
WORKDIR /srv
COPY pyproject.toml ./
COPY app ./app
RUN pip install . && useradd -u 1000 -m brain && mkdir -p /data && chown brain /data
COPY tests ./tests
USER brain
EXPOSE 8080
HEALTHCHECK --interval=60s --timeout=5s CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/favicon.ico')" || exit 1
CMD ["uvicorn", "app.main:factory", "--factory", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--timeout-keep-alive", "75"]

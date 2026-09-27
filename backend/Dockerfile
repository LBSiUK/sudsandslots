FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SUDS_DB=/data/suds.db \
    TZ=Europe/London

WORKDIR /srv
COPY requirements.txt requirements-dev.txt ./
# pytest ships in the image so the suite runs where the app runs:
#   docker compose run --rm api pytest -q
RUN pip install --no-cache-dir -r requirements.txt -r requirements-dev.txt

COPY app ./app
COPY tests ./tests
COPY pytest.ini ./

RUN useradd --system --uid 10001 --home-dir /srv suds \
 && mkdir -p /data && chown suds:suds /data
USER suds
VOLUME /data
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=4).status == 200 else 1)"

CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", \
     "--proxy-headers", "--timeout-graceful-shutdown", "3"]

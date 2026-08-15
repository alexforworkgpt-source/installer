services:
  postgres:
    image: "__POSTGRES_IMAGE__"
    restart: unless-stopped
    environment:
      POSTGRES_DB: "__POSTGRES_DB__"
      POSTGRES_USER: "__POSTGRES_USER__"
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U __POSTGRES_USER__ -d __POSTGRES_DB__"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s

  redis:
    image: "__REDIS_IMAGE__"
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory 256mb --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 5s
      retries: 3

  bot:
    build:
      context: "__BOT_REPO_DIR__"
      dockerfile: Dockerfile
    user: "1000:1000"
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    env_file:
      - "__BOT_ENV_FILE__"
      - "__BOT_OVERRIDE_ENV_FILE__"
    environment:
      FORCE_COLOR: "1"
      DOCKER_ENV: "true"
    volumes:
      - "__BOT_DATA_DIR__:/app/data"
      - "__BOT_LOGS_DIR__:/app/logs"
      - "__BOT_UPLOADS_DIR__:/app/uploads"
    ports:
      - "127.0.0.1:__BOT_HTTP_PORT__:8080"
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8080/cabinet/branding')\""]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 30s

volumes:
  postgres_data:
  redis_data:

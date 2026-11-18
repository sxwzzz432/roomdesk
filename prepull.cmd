@echo off
rem Pre-pull base images so `docker compose up -d --build` does not need to ask
rem auth.docker.io for manifest metadata (that request often times out behind a
rem proxy / in CN networks, while plain image pulls still work).
setlocal
for %%i in (python:3.12-slim postgres:16-alpine adminer:4 alpine:3.20) do (
  echo === pulling %%i ===
  docker pull %%i
  if errorlevel 1 echo [WARN] %%i pull failed - retry, or configure Docker Desktop proxy
)
echo.
docker image ls --format "table {{.Repository}}:{{.Tag}}  {{.Size}}"
echo.
echo Next:  docker compose up -d --build
pause
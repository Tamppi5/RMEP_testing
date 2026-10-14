@echo off
rem cmd.exe runs this instead of docker.exe when called from the repository root.
rem   docker compose up -<FolderName>  -> zip the folder to the repo root and start the stack
rem Everything else (including -d, -V, -dV, --build ...) goes to the real docker.exe.
setlocal

if /i not "%~1"=="compose" goto :passthrough
if /i not "%~2"=="up" goto :passthrough

set "ARG=%~3"
if not defined ARG goto :passthrough
if not "%ARG:~0,1%"=="-" goto :passthrough
if "%ARG:~1,1%"=="-" goto :passthrough
set "FOLDER=%ARG:~1%"
echo %FOLDER%| findstr /r /c:"^[dVtyw]*$" >nul && goto :passthrough

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup-and-start.ps1" -FolderName "%FOLDER%" -StartDocker
exit /b %errorlevel%

:passthrough
docker.exe %*
exit /b %errorlevel%

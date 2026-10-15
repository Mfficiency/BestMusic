@echo off
rem Best Music Organizer: double-click to start. Needs Python 3.10+ (python.org or winget install Python.Python.3.12)
rem and ffmpeg for downloads (winget install Gyan.FFmpeg).
cd /d "%~dp0"
where py >nul 2>nul && (set PY=py -3) || (set PY=python)
%PY% -m pip install --quiet --upgrade -r requirements.txt
%PY% organizer.py %*
pause

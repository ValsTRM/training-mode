@echo off
rem Double-click: opens the Training Mode window (Windows asks for admin once).
rem Command line:  "Training Mode.cmd" on   |   off   |   status
rem                "Training Mode.cmd" on -GpuPercent 70 -DisplayOffMinutes 10
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not "%~1"=="" goto cli
start "" "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0TrainingMode.ps1"
goto :eof
:cli
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0TrainingMode.ps1" -Action %*

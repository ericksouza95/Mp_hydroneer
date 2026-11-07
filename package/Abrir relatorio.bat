@echo off
if exist "%LOCALAPPDATA%\HydroneerMP\relatorio.txt" (
    start "" notepad "%LOCALAPPDATA%\HydroneerMP\relatorio.txt"
) else (
    echo Ainda nao existe relatorio. Abra o jogo com o mod instalado primeiro.
    pause
)

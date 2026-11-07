# Encerra a copia de teste, instala o mod com uma configuracao e inicia o jogo em janela.
# Nunca toca em processos fora de E:\hydroneer-qa.
# Uso: powershell -ExecutionPolicy Bypass -File tools\run-test.ps1 -Instance E:\hydroneer-qa\inst0 -Config "k=v,k=v" [-Dll caminho] [-X 0 -Y 0]
param(
    [string]$Instance = "E:\hydroneer-qa\inst0",
    [string]$Mod = "MpHydroneer",
    [string]$Config = "",
    [string]$Dll = "",
    [int]$X = -1, [int]$Y = -1
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if ($Instance -like "*steamapps*") { throw "recusado: $Instance parece a instalacao Steam" }
$w64 = Join-Path $Instance "Mining\Binaries\Win64"
$exe = Join-Path $w64 "Mining-Win64-Shipping.exe"

Get-Process Mining-Win64-Shipping, CrashReportClient -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($Instance, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Stop-Process -Id $_.Id -Force; Write-Host "encerrado $($_.ProcessName) $($_.Id)" }
Start-Sleep -Milliseconds 1500

& (Join-Path $PSScriptRoot "deploy-test.ps1") -Instance $Instance -Mod $Mod -Config $Config
if ($Dll) { Copy-Item $Dll (Join-Path $w64 "ue4ss\Mods\$Mod\native\mpnet.dll") -Force }

$args = @("-windowed", "-ResX=960", "-ResY=540", "-userdir=QaUser")
if ($X -ge 0) { $args += @("-WinX=$X", "-WinY=$Y") }
$p = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $w64 -PassThru
$pidFile = Join-Path "E:\hydroneer-qa\out" ("{0}.pid" -f (Split-Path $Instance -Leaf))
Set-Content $pidFile $p.Id
"PID $($p.Id) -> $pidFile"

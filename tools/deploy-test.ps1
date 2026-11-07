# Instala a ponte mpnet e o mod de autoteste numa copia de teste do jogo (nunca na instalacao Steam).
# Uso: powershell -ExecutionPolicy Bypass -File tools\deploy-test.ps1 [-Instance E:\hydroneer-qa\inst0]
param([string]$Instance = "E:\hydroneer-qa\inst0")
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$w64 = Join-Path $Instance "Mining\Binaries\Win64"
$mods = Join-Path $w64 "ue4ss\Mods"
if (-not (Test-Path (Join-Path $w64 "ue4ss\UE4SS.dll"))) { throw "UE4SS nao encontrado em $w64" }
if ($Instance -like "*steamapps*") { throw "recusado: $Instance parece a instalacao Steam" }

$dll = Join-Path $root "native\mpnet\build\mpnet.dll"
if (-not (Test-Path $dll)) { throw "compile antes: native\mpnet\build.ps1" }

$dst = Join-Path $mods "MpNetTest"
New-Item -ItemType Directory -Force (Join-Path $dst "Scripts"), (Join-Path $dst "native") | Out-Null
Copy-Item (Join-Path $root "mod\MpNetTest\Scripts\main.lua") (Join-Path $dst "Scripts\main.lua") -Force
Copy-Item (Join-Path $root "lua\mpnet.lua") (Join-Path $dst "Scripts\mpnet.lua") -Force
Copy-Item $dll (Join-Path $dst "native\mpnet.dll") -Force
Remove-Item (Join-Path $dst "mpnet-test.txt"), (Join-Path $dst "native\mpnet.log"), (Join-Path $dst "native\mpnet.token") -ErrorAction SilentlyContinue

# mods.txt e mods.json: MpNetTest ligado, MpSpike desligado
$txt = Join-Path $mods "mods.txt"
$lines = Get-Content $txt | Where-Object { $_ -notmatch '^\s*(MpNetTest|MpSpike)\s*:' }
Set-Content $txt (@("MpNetTest : 1", "MpSpike : 0") + $lines) -Encoding ascii
$json = Join-Path $mods "mods.json"
$list = @(Get-Content $json -Raw | ConvertFrom-Json | Where-Object { $_.mod_name -notin @("MpNetTest", "MpSpike") })
$list = @([pscustomobject]@{ mod_name = "MpNetTest"; mod_enabled = $true }, [pscustomobject]@{ mod_name = "MpSpike"; mod_enabled = $false }) + $list
$list | ConvertTo-Json | Set-Content $json -Encoding ascii
"instalado em $dst"

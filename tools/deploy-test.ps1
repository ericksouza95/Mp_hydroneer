# Instala a ponte mpnet e um mod nosso numa copia de teste do jogo (nunca na instalacao Steam).
# Uso: powershell -ExecutionPolicy Bypass -File tools\deploy-test.ps1 [-Mod MpNetTest|MpPing] [-AutoTest] [-Instance E:\hydroneer-qa\inst0]
param(
    [string]$Instance = "E:\hydroneer-qa\inst0",
    [ValidateSet("MpNetTest", "MpPing")][string]$Mod = "MpNetTest",
    [switch]$AutoTest
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$w64 = Join-Path $Instance "Mining\Binaries\Win64"
$mods = Join-Path $w64 "ue4ss\Mods"
if (-not (Test-Path (Join-Path $w64 "ue4ss\UE4SS.dll"))) { throw "UE4SS nao encontrado em $w64" }
if ($Instance -like "*steamapps*") { throw "recusado: $Instance parece a instalacao Steam" }

$dll = Join-Path $root "native\mpnet\build\mpnet.dll"
if (-not (Test-Path $dll)) { throw "compile antes: native\mpnet\build.ps1" }

$dst = Join-Path $mods $Mod
New-Item -ItemType Directory -Force (Join-Path $dst "Scripts"), (Join-Path $dst "native") | Out-Null
Copy-Item (Join-Path $root "mod\$Mod\Scripts\main.lua") (Join-Path $dst "Scripts\main.lua") -Force
Copy-Item (Join-Path $root "lua\mpnet.lua") (Join-Path $dst "Scripts\mpnet.lua") -Force
Copy-Item $dll (Join-Path $dst "native\mpnet.dll") -Force
Remove-Item (Join-Path $dst "mpnet-test.txt"), (Join-Path $dst "native\mpnet.log"), (Join-Path $dst "native\mpnet.token") -ErrorAction SilentlyContinue
$flag = Join-Path $dst "autoteste.txt"
if ($AutoTest) { Set-Content $flag "1" -Encoding ascii } else { Remove-Item $flag -ErrorAction SilentlyContinue }

# Exatamente um dos nossos mods ligado
$ours = @("MpNetTest", "MpPing", "MpSpike")
$txt = Join-Path $mods "mods.txt"
$lines = Get-Content $txt | Where-Object { $_ -notmatch ('^\s*(' + ($ours -join '|') + ')\s*:') }
$head = $ours | ForEach-Object { "$_ : " + $(if ($_ -eq $Mod) { 1 } else { 0 }) }
Set-Content $txt (@($head) + $lines) -Encoding ascii
$json = Join-Path $mods "mods.json"
$list = @(Get-Content $json -Raw | ConvertFrom-Json | Where-Object { $_.mod_name -notin $ours })
$list = @($ours | ForEach-Object { [pscustomobject]@{ mod_name = $_; mod_enabled = ($_ -eq $Mod) } }) + $list
$list | ConvertTo-Json | Set-Content $json -Encoding ascii
"instalado $Mod em $dst" + $(if ($AutoTest) { " (autoteste)" } else { "" })

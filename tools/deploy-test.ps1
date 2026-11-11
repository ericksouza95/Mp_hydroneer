# Instala a ponte mpnet e um mod nosso numa copia de teste do jogo (nunca na instalacao Steam).
# Uso: powershell -ExecutionPolicy Bypass -File tools\deploy-test.ps1 [-Mod MpHydroneer|MpPing|MpNetTest]
#        [-Instance E:\hydroneer-qa\inst0] [-Config "transport=udp","role=host"] [-AutoTest]
param(
    [string]$Instance = "E:\hydroneer-qa\inst0",
    [ValidateSet("MpNetTest", "MpPing", "MpHydroneer", "MpSaveTest")][string]$Mod = "MpHydroneer",
    [string[]]$Config = @(),
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
if (Test-Path (Join-Path $dst "Scripts")) { Remove-Item (Join-Path $dst "Scripts") -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $dst "Scripts"), (Join-Path $dst "native") | Out-Null
Copy-Item (Join-Path $root "mod\$Mod\Scripts\*.lua") (Join-Path $dst "Scripts\") -Force
Copy-Item (Join-Path $root "lua\*.lua") (Join-Path $dst "Scripts\") -Force   # bibliotecas compartilhadas
Copy-Item $dll (Join-Path $dst "native\mpnet.dll") -Force
Remove-Item (Join-Path $dst "mpnet-test.txt"), (Join-Path $dst "native\mpnet.log"), (Join-Path $dst "native\mpnet.token") -ErrorAction SilentlyContinue
$flag = Join-Path $dst "autoteste.txt"
if ($AutoTest) { Set-Content $flag "1" -Encoding ascii } else { Remove-Item $flag -ErrorAction SilentlyContinue }
$cfgFile = Join-Path $dst "mp-config.txt"
# -Config chega como um item so quando o script e chamado com -File; separa por virgula.
$Config = @($Config | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Config.Count -gt 0) { Set-Content $cfgFile $Config -Encoding ascii } else { Remove-Item $cfgFile -ErrorAction SilentlyContinue }

# Exatamente um dos nossos mods ligado
$ours = @("MpNetTest", "MpPing", "MpSpike", "MpHydroneer", "MpSaveTest")
$txt = Join-Path $mods "mods.txt"
$lines = Get-Content $txt | Where-Object { $_ -notmatch ('^\s*(' + ($ours -join '|') + ')\s*:') }
$head = $ours | ForEach-Object { "$_ : " + $(if ($_ -eq $Mod) { 1 } else { 0 }) }
Set-Content $txt (@($head) + $lines) -Encoding ascii
$json = Join-Path $mods "mods.json"
$raw = Get-Content $json -Raw | ConvertFrom-Json
if ($raw.value) { $raw = $raw.value }   # conserta o invólucro que versoes antigas deste script gravaram
$list = @($raw | Where-Object { $_.mod_name -and $_.mod_name -notin $ours })
$list = @($ours | ForEach-Object { [pscustomobject]@{ mod_name = $_; mod_enabled = ($_ -eq $Mod) } }) + $list
ConvertTo-Json -InputObject $list | Set-Content $json -Encoding ascii
"instalado $Mod em $dst" + $(if ($Config.Count) { " com " + ($Config -join ", ") } else { "" })

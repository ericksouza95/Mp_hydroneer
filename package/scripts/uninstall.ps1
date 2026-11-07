# Desinstalador do Hydroneer MP. Chamado por Desinstalar.bat.
# Remove so os arquivos que o instalador adicionou e devolve os que ele tinha copiado para backup.
param([string]$DataDir)
$ErrorActionPreference = "Stop"
$data = if ($DataDir) { $DataDir } else { Join-Path $env:LOCALAPPDATA "HydroneerMP" }
$manifestPath = Join-Path $data "install.json"

Write-Host ""
Write-Host "=== Hydroneer MP: desinstalacao ==="
if (-not (Test-Path $manifestPath)) { Write-Host "Nada instalado (nao achei $manifestPath)."; exit 0 }
$m = Get-Content $manifestPath -Raw | ConvertFrom-Json
$running = @(Get-Process -Name "Mining-Win64-Shipping" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($m.game_dir, [StringComparison]::OrdinalIgnoreCase) })
if ($running.Count -gt 0) { Write-Host "Feche o Hydroneer antes."; exit 2 }

$removed = 0
foreach ($f in $m.added) {
    if (Test-Path $f) { Remove-Item $f -Force; $removed++ }
}
foreach ($b in $m.backups) {
    if (Test-Path $b.Backup) { Copy-Item $b.Backup $b.File -Force }
}
# A pasta que o instalador criou sai inteira, com os logs e o cache que o UE4SS e a ponte geram.
# Modo "full": a pasta ue4ss nao existia antes. Modo "mod": so a pasta do MpPing e nossa.
$modName = if ($m.mod_name) { $m.mod_name } else { "MpPing" }   # a 0.1 nao gravava o nome
$root = if ($m.mode -eq "full") { Join-Path $m.win64 "ue4ss" } else { Join-Path $m.mods_dir $modName }
if ((Test-Path $root) -and ($root -like "*\Mining\Binaries\Win64\*")) { Remove-Item $root -Recurse -Force }
Remove-Item $manifestPath -Force
Write-Host "Removidos $removed arquivos. O relatorio continua em $data\relatorio.txt"
exit 0

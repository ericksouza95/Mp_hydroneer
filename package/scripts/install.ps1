# Instalador do Hydroneer MP (teste de conexao). Chamado por Instalar.bat.
# So adiciona arquivos na pasta do jogo. Qualquer arquivo que ja existia e copiado para backup antes.
param([string]$GameDir, [switch]$Yes, [string]$DataDir)
$ErrorActionPreference = "Stop"
$TestedBuild = "23218978"
$pkg = Split-Path $PSScriptRoot -Parent
$files = Join-Path $pkg "files"
$data = if ($DataDir) { $DataDir } else { Join-Path $env:LOCALAPPDATA "HydroneerMP" }
$manifestPath = Join-Path $data "install.json"

function Say($t) { Write-Host $t }
function Ask($t) { if ($Yes) { return $true }; $a = Read-Host "$t (s/n)"; return $a -match '^[sSyY]' }

function Find-Game {
    $steam = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try { $p = Get-ItemProperty $k -ErrorAction Stop; $steam = if ($p.SteamPath) { $p.SteamPath } else { $p.InstallPath }; if ($steam) { break } } catch {}
    }
    if (-not $steam) { return $null }
    $libs = @($steam -replace '/', '\')
    $vdf = Join-Path $libs[0] "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' | ForEach-Object { $libs += ($_.Matches[0].Groups[1].Value -replace '\\\\', '\') }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $acf = Join-Path $l "steamapps\appmanifest_1106840.acf"
        if (Test-Path $acf) {
            $dir = (Select-String -Path $acf -Pattern '"installdir"\s+"([^"]+)"').Matches[0].Groups[1].Value
            $build = (Select-String -Path $acf -Pattern '"buildid"\s+"([^"]+)"').Matches[0].Groups[1].Value
            return @{ Dir = (Join-Path $l "steamapps\common\$dir"); Build = $build }
        }
    }
    return $null
}

Say ""
Say "=== Hydroneer MP: instalacao ==="
$modName = (Get-ChildItem (Join-Path $files "ue4ss\Mods") -Directory | Select-Object -First 1).Name
$pkgVersion = [string](Get-Content (Join-Path $pkg "VERSAO.txt") -ErrorAction SilentlyContinue | Select-Object -First 1)
$pkgVersion = $pkgVersion.Trim()

function Game-Running($dir) {
    @(Get-Process -Name "Mining-Win64-Shipping" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
}

$build = "?"
if ($GameDir) {
    $game = $GameDir
    $acf = Join-Path (Split-Path (Split-Path $game -Parent) -Parent) "appmanifest_1106840.acf"
    if (Test-Path $acf) { $build = (Select-String -Path $acf -Pattern '"buildid"\s+"([^"]+)"').Matches[0].Groups[1].Value }
} else {
    $g = Find-Game
    if (-not $g) { Say "Nao achei o Hydroneer pela Steam. Rode de novo passando a pasta: Instalar.bat ""D:\caminho\Hydroneer"""; exit 2 }
    $game = $g.Dir; $build = $g.Build
}
$w64 = Join-Path $game "Mining\Binaries\Win64"
if (-not (Test-Path (Join-Path $w64 "Mining-Win64-Shipping.exe"))) { Say "Pasta do jogo invalida: $game"; exit 2 }
if (Game-Running $game) { Say "Feche o Hydroneer antes de instalar."; exit 2 }
if (Test-Path $manifestPath) {
    $old = Get-Content $manifestPath -Raw | ConvertFrom-Json
    Say "Removendo a versao anterior ($($old.version)) antes de instalar a nova..."
    powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "uninstall.ps1") -DataDir $data
    if (Test-Path $manifestPath) { Say "Nao consegui remover a versao anterior. Rode Desinstalar.bat."; exit 2 }
}
Say "Jogo: $game"
Say "Versao Steam: $build (testado com $TestedBuild)"
if ($build -ne $TestedBuild) {
    Say "AVISO: sua versao do jogo e diferente da testada. Pode nao funcionar, e voce e seu amigo precisam da mesma versao."
    if (-not (Ask "Instalar mesmo assim?")) { Say "Nada foi alterado."; exit 3 }
}

# UE4SS ja instalado por outro mod? Entao so adicionamos o nosso mod.
$existingUe4ss = (Test-Path (Join-Path $w64 "ue4ss\UE4SS.dll")) -or (Test-Path (Join-Path $w64 "UE4SS.dll"))
if ($existingUe4ss) {
    $modsDir = if (Test-Path (Join-Path $w64 "ue4ss\Mods")) { Join-Path $w64 "ue4ss\Mods" } else { Join-Path $w64 "Mods" }
    Say "UE4SS ja existe nesta pasta; vou adicionar so o mod $modName."
    $plan = @(@{ From = Join-Path $files "ue4ss\Mods\$modName"; To = Join-Path $modsDir $modName })
} else {
    $modsDir = Join-Path $w64 "ue4ss\Mods"
    $plan = @(
        @{ From = Join-Path $files "dwmapi.dll"; To = Join-Path $w64 "dwmapi.dll" },
        @{ From = Join-Path $files "ue4ss"; To = Join-Path $w64 "ue4ss" }
    )
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $data "backup\$stamp"
$added = @(); $backedUp = @()
New-Item -ItemType Directory -Force $data | Out-Null
foreach ($step in $plan) {
    $srcItems = if (Test-Path $step.From -PathType Container) { Get-ChildItem $step.From -Recurse -File } else { @(Get-Item $step.From) }
    foreach ($f in $srcItems) {
        $rel = if (Test-Path $step.From -PathType Container) { $f.FullName.Substring($step.From.Length).TrimStart('\') } else { "" }
        $dst = if ($rel) { Join-Path $step.To $rel } else { $step.To }
        if (Test-Path $dst) {
            $b = Join-Path $backup ($dst.Substring($game.Length).TrimStart('\'))
            New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
            Copy-Item $dst $b -Force
            $backedUp += @{ File = $dst; Backup = $b }
        }
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item $f.FullName $dst -Force
        Unblock-File $dst -ErrorAction SilentlyContinue
        $added += $dst
    }
}

# Ligar o mod quando o UE4SS ja existia
$modsTxtEdited = $false
if ($existingUe4ss) {
    $txt = Join-Path $modsDir "mods.txt"
    if (Test-Path $txt) {
        $b = Join-Path $backup "mods.txt"; New-Item -ItemType Directory -Force $backup | Out-Null; Copy-Item $txt $b -Force
        $lines = Get-Content $txt | Where-Object { $_ -notmatch ('^\s*' + $modName + '\s*:') }
        Set-Content $txt (@("$modName : 1") + $lines) -Encoding ascii
        $modsTxtEdited = $true; $backedUp += @{ File = $txt; Backup = $b }
    }
}

$manifest = [ordered]@{
    version = $pkgVersion; mod_name = $modName; installed = $stamp; game_dir = $game; win64 = $w64; mode = $(if ($existingUe4ss) { "mod" } else { "full" })
    added = $added; backups = $backedUp; mods_txt_edited = $modsTxtEdited; mods_dir = $modsDir
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content $manifestPath -Encoding utf8

Say ""
Say "Pronto. $($added.Count) arquivos instalados."
Say "Relatorio do teste vai ficar em: $data\relatorio.txt"
Say "Leia o LEIA-ME.txt para os passos do teste."
exit 0

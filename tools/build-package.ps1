# Monta o pacote para jogadores: dist\HydroneerMP-<versao>\ e o zip.
# Uso: powershell -ExecutionPolicy Bypass -File tools\build-package.ps1 -Ue4ssZip <UE4SS_v3.0.1-1217-g4fb9b615.zip> [-Version 0.2] [-Mod MpHydroneer]
param(
    [Parameter(Mandatory = $true)][string]$Ue4ssZip,
    [string]$Version = "0.2",
    [string]$Mod = "MpHydroneer"
)
$ErrorActionPreference = "Stop"
$Ue4ssSha256 = "FBDACD0FAE434E23D53B1181F6B085219D7CBF7E2CC8A13A00303F842C38194F"   # v3.0.1-1217-g4fb9b615
$root = Split-Path $PSScriptRoot -Parent

if ((Get-FileHash $Ue4ssZip -Algorithm SHA256).Hash -ne $Ue4ssSha256) { throw "SHA-256 do UE4SS nao confere" }
$dll = Join-Path $root "native\mpnet\build\mpnet.dll"
if (-not (Test-Path $dll)) { throw "compile antes: native\mpnet\build.ps1" }

$name = "HydroneerMP-$Version"
$dist = Join-Path $root "dist"
$out = Join-Path $dist $name
$work = Join-Path $dist "_ue4ss"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force $out, $work | Out-Null
Expand-Archive -LiteralPath $Ue4ssZip -DestinationPath $work

# Raiz do pacote
Copy-Item (Join-Path $root "package\*") $out -Recurse
Set-Content (Join-Path $out "VERSAO.txt") "$Version" -Encoding ascii
# UE4SS sem os mods de exemplo
$f = Join-Path $out "files"
$modDst = Join-Path $f "ue4ss\Mods\$Mod"
New-Item -ItemType Directory -Force (Join-Path $modDst "Scripts"), (Join-Path $modDst "native"), (Join-Path $out "licenses") | Out-Null
Copy-Item (Join-Path $work "dwmapi.dll") $f
foreach ($x in "UE4SS.dll", "UE4SS-settings.ini", "LICENSE") { Copy-Item (Join-Path $work "ue4ss\$x") (Join-Path $f "ue4ss\") }
Copy-Item (Join-Path $work "ue4ss\LICENSE") (Join-Path $out "licenses\UE4SS-LICENSE.txt")
Set-Content (Join-Path $f "ue4ss\Mods\mods.txt") "$Mod : 1" -Encoding ascii
Set-Content (Join-Path $f "ue4ss\Mods\mods.json") "[ { `"mod_name`": `"$Mod`", `"mod_enabled`": true } ]" -Encoding ascii
# Mod e ponte
Copy-Item (Join-Path $root "mod\$Mod\Scripts\*.lua") (Join-Path $modDst "Scripts\")
Copy-Item (Join-Path $root "lua\*.lua") (Join-Path $modDst "Scripts\")   # bibliotecas compartilhadas
Copy-Item $dll (Join-Path $modDst "native\")

# Fim de linha do Windows nos .bat e .txt
Get-ChildItem $out -Recurse -Include *.bat, *.txt | ForEach-Object {
    $t = [IO.File]::ReadAllText($_.FullName) -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($_.FullName, $t, (New-Object Text.UTF8Encoding($false)))
}

Remove-Item $work -Recurse -Force
$zip = Join-Path $dist "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $out -DestinationPath $zip
Get-ChildItem $out -Recurse -File | Select-Object @{ n = "Arquivo"; e = { $_.FullName.Substring($out.Length + 1) } }, Length | Format-Table -AutoSize
"zip: $zip"
"tamanho: {0:N1} MB" -f ((Get-Item $zip).Length / 1MB)
"SHA-256: " + (Get-FileHash $zip -Algorithm SHA256).Hash

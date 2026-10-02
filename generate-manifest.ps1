<#
.SYNOPSIS
    Генерирует manifest.json для лаунчера MyPack.
.EXAMPLE
    .\generate-manifest.ps1 -PackName "MyPack" -PackVersion "1.0.0" -GitHubRepo "yourname/mypack-pack"
.EXAMPLE
    # Все моды лежат в одном постоянном релизе "mods"; -FixNames приводит имена файлов к безопасным
    .\generate-manifest.ps1 -PackName "MyPack" -PackVersion "1.0.0" -GitHubRepo "yourname/mypack-pack" -ReleaseTag mods -FixNames
#>

param(
    [Parameter(Mandatory = $true)] [string]$PackName,
    [Parameter(Mandatory = $true)] [string]$PackVersion,
    [string]$MinecraftVersion = "1.21.1",
    [string]$NeoForgeVersion = "21.1.234",
    [Parameter(Mandatory = $true)] [string]$GitHubRepo,
    [string]$ModsPath = "mods",
    [string]$OutputPath = "manifest.json",
    [string]$MaxMemory = "4096M",
    [string]$MinMemory = "2048M",
    # Тег релиза на GitHub, где лежат .jar. По умолчанию "v<PackVersion>" (новый релиз на каждую версию).
    # Если указать постоянный тег (например "mods"), новые версии сборки докидывают только новые файлы.
    [string]$ReleaseTag = "",
    # Переименовать файлы с небезопасными именами (пробелы, скобки, "+" и т.п.) прямо в папке модов.
    [switch]$FixNames,
    # Моды лежат прямо в репозитории (папка mods) и качаются по raw-ссылкам, без релизов GitHub.
    # Проще всего: положили .jar в папку репозитория, запустили скрипт, закоммитили и запушили.
    [switch]$FromRepo
)

if (-not $ReleaseTag) { $ReleaseTag = "v$PackVersion" }

$ErrorActionPreference = "Stop"

Write-Host "=== MyPack Launcher: генерация манифеста ===" -ForegroundColor Green
Write-Host "Сборка: $PackName v$PackVersion"
Write-Host "Minecraft: $MinecraftVersion + NeoForge $NeoForgeVersion"
Write-Host ""

if (-not (Test-Path $ModsPath)) {
    Write-Error "Папка модов не найдена: $ModsPath"
    exit 1
}

$files = @()
$mods = Get-ChildItem -Path $ModsPath -Recurse -File | Sort-Object FullName

# GitHub меняет "странные" имена при загрузке в релиз (пробелы -> точки и т.д.), и ссылки ломаются.
$bad = if ($FromRepo) { @() } else { @($mods | Where-Object { $_.Name -notmatch '^[A-Za-z0-9._-]+$' }) }
if ($bad.Count -gt 0) {
    if ($FixNames) {
        foreach ($f in $bad) {
            $newName = $f.Name -replace '[^A-Za-z0-9._-]', '_'
            Rename-Item -LiteralPath $f.FullName -NewName $newName
            Write-Host "  [rename] $($f.Name) -> $newName" -ForegroundColor Yellow
        }
        $mods = Get-ChildItem -Path $ModsPath -Recurse -File | Sort-Object FullName
    }
    else {
        Write-Host "Файлы с небезопасными именами ($($bad.Count) шт.):" -ForegroundColor Red
        $bad | ForEach-Object { Write-Host "  $($_.Name)" }
        Write-Error "Запустите скрипт с ключом -FixNames (заменит недопустимые символы на '_') или переименуйте файлы вручную."
        exit 1
    }
}

$dupes = if ($FromRepo) { @() } else { @($mods | Group-Object Name | Where-Object { $_.Count -gt 1 }) }
if ($dupes.Count -gt 0) {
    $dupes | ForEach-Object { Write-Host "Повторяющееся имя файла: $($_.Name)" -ForegroundColor Red }
    Write-Error "Имена файлов в релизе должны быть уникальны, даже если файлы лежат в разных подпапках."
    exit 1
}

if ($mods.Count -eq 0) {
    Write-Warning "Папка $ModsPath пустая — манифест будет без файлов"
}

Write-Host "Найдено файлов: $($mods.Count)"
Write-Host ""

foreach ($file in $mods) {
    $relativePath = $file.FullName.Substring((Resolve-Path $ModsPath).Path.Length + 1)
    $relativePath = $relativePath -replace '\\', '/'
    $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA1).Hash.ToLower()
    $size = $file.Length
    if ($FromRepo) {
        $encoded = (($relativePath -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $url = "https://raw.githubusercontent.com/$GitHubRepo/main/mods/$encoded"
    }
    else {
        $url = "https://github.com/$GitHubRepo/releases/download/$ReleaseTag/$($file.Name)"
    }

    Write-Host "  [+] $relativePath" -ForegroundColor Cyan

    $files += [ordered]@{
        path     = "mods/$relativePath"
        url      = $url
        sha1     = $hash
        size     = $size
        required = $true
    }
}

$manifest = [ordered]@{
    packName         = $PackName
    packVersion      = $PackVersion
    minecraftVersion = $MinecraftVersion
    modLoader        = [ordered]@{ type = "neoforge"; version = $NeoForgeVersion }
    launchArgs       = [ordered]@{
        maxMemory = $MaxMemory
        minMemory = $MinMemory
        jvmArgs   = @("-XX:+UseG1GC", "-XX:+ParallelRefProcEnabled")
    }
    files            = $files
    overrides        = @()
    deleteOnUpdate   = @()
}

$json = $manifest | ConvertTo-Json -Depth 10
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path (Get-Location) $OutputPath), $json, $utf8NoBom)

Write-Host ""
Write-Host "=== Готово ===" -ForegroundColor Green
Write-Host "Манифест записан: $OutputPath"
Write-Host ""
Write-Host "Следующие шаги:" -ForegroundColor Yellow
if ($FromRepo) {
    Write-Host "  1. В GitHub Desktop: коммит (папка mods + manifest.json) и Push origin"
}
else {
    Write-Host "  1. Загрузите .jar в релиз '$ReleaseTag' репозитория ${GitHubRepo}:"
    Write-Host "       .\upload-mods.ps1 -GitHubRepo $GitHubRepo -ReleaseTag $ReleaseTag -ModsPath $ModsPath"
    Write-Host "  2. Закоммитьте manifest.json в корень репозитория (ветка main)"
}
Write-Host "  Ссылка для лаунчера будет такой:"
Write-Host "     https://raw.githubusercontent.com/$GitHubRepo/main/manifest.json"

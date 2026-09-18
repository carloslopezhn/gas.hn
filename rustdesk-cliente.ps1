$ErrorActionPreference='Stop'
Write-Host '== RustDesk CLIENTE (desatendido) - soporte.gas.hn ==' -ForegroundColor Cyan
$exe="$env:TEMP\rustdesk-setup.exe"
$rel=Invoke-RestMethod 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest'
$url=($rel.assets | Where-Object { $_.name -match 'x86_64\.exe$' } | Select-Object -First 1).browser_download_url
if(-not $url){ throw 'No se encontro el instalador de RustDesk.' }
Write-Host "Descargando $url ..."
Invoke-WebRequest $url -OutFile $exe -UseBasicParsing
Write-Host 'Instalando (silencioso)...'
& $exe --silent-install
Start-Sleep -Seconds 25
$rd="$env:ProgramFiles\RustDesk\RustDesk.exe"
if(-not (Test-Path $rd)){ $rd="${env:ProgramFiles(x86)}\RustDesk\RustDesk.exe" }
if(-not (Test-Path $rd)){ throw 'RustDesk no quedo instalado.' }
$toml="$env:TEMP\RustDesk2.toml"
@"
[options]
custom-rendezvous-server = 'soporte.gas.hn'
relay-server = 'soporte.gas.hn'
api-server = 'https://soporte.gas.hn:21114'
key = 'rwLCyTRWR5al5H1D07tByLIyJE1uZEVMOl2tkjUfgQg='
"@ | Set-Content -Path $toml -Encoding UTF8
& $rd --import-config $toml
Start-Sleep -Seconds 3
& $rd --password 'Acero200??@#'
Write-Host 'LISTO. Acceso DESATENDIDO configurado (pass fija). Anota el ID que muestra RustDesk.' -ForegroundColor Green

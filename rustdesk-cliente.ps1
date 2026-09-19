$ErrorActionPreference='Stop'
Write-Host '== RustDesk CLIENTE (desatendido) - soporte.gas.hn ==' -ForegroundColor Cyan
$exe="$env:TEMP\rustdesk-setup.exe"
# Version: LATEST (resuelta por la API de GitHub: el asset lleva la version en el
# nombre, asi que 'releases/latest/download/rustdesk-x86_64.exe' da 404).
# El pin a 1.3.9 fue un workaround del bug "Failed to secure tcp: deadline has elapsed"
# (cliente >=1.4.1 logueado a la consola contra un hbbs sin el handshake secure_tcp).
# RESUELTO EN EL SERVIDOR el 2026-09-19: hbbs 1.1.17 con el parche del PR
# rustdesk-server#706 -> los clientes nuevos ya conectan sin downgrade.
$url=$null
try{
  $rel=Invoke-RestMethod 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -UseBasicParsing
  $url=($rel.assets | Where-Object { $_.name -match 'x86_64\.exe$' } | Select-Object -First 1).browser_download_url
}catch{ Write-Host 'API de GitHub no disponible; uso version de respaldo.' -ForegroundColor Yellow }
if(-not $url){ $url='https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.exe' }
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

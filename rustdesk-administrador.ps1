$ErrorActionPreference='Stop'
Write-Host '== RustDesk ADMINISTRADOR - soporte.gas.hn ==' -ForegroundColor Cyan
$exe="$env:TEMP\rustdesk-setup.exe"
# PIN 1.3.9 (NO usar 'latest'): el server hbbs 1.1.16 self-hosted NO implementa el
# handshake secure_tcp que el cliente >=1.4.1 exige cuando esta logueado a la API/consola
# -> "Failed to secure tcp: deadline has elapsed" (peer ONLINE pero no conecta).
# 1.3.9 es la ultima version que NO lo exige y es 100% compatible con este server.
$ver='1.3.9'
$url="https://github.com/rustdesk/rustdesk/releases/download/$ver/rustdesk-$ver-x86_64.exe"
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
Write-Host 'LISTO. RustDesk apunta a soporte.gas.hn. Abrilo para conectar.' -ForegroundColor Green

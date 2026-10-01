#!/bin/bash
# =============================================================================
# install-ubuntu.sh — Instalador de estación Gas+ para UBUNTU SERVER nativo
#                     (22.04 / 24.04, máquina física o VM, SIN Hyper-V/Windows).
# -----------------------------------------------------------------------------
# Uso (un solo comando, en el servidor recién instalado):
#
#   curl -fsSL https://gas.hn/install-ubuntu.sh | sudo bash -s -- --codigo <CÓDIGO>
#
# Pregunta nombre, subdominio y modo (con valores por defecto). Sin preguntas:
#   … | sudo bash -s -- --codigo <CÓDIGO> --nombre "Shell X" --subdominio shellx --modo fusion --si
#
# <CÓDIGO> = código de instalación del panel (el MISMO token de provisión que usa el
# g+ Installer de Windows contra panel.gas.hn/api/provision-station). Con él el panel
# da de alta la estación y DEVUELVE los secretos (túnel, agente, token interno, licencia,
# update-key, credencial de SOLO LECTURA del registry). Este script es público: NO
# lleva ningún secreto embebido.
#
# Deja la estación IDÉNTICA a una nacida de la VHDX (docs/instalacion-estandar.md):
# mismo kit (gas.hn/gasplus-station-kit.tar.gz, verificado por sha256 sellado abajo),
# mismo compose -p pos_gas, misma librería (lib/gasplus-station.sh) y mismo firstboot.
#
# Idempotente: re-ejecutable (reusa el .env, los tokens y la DB). Log en
# /var/log/gasplus-install.log. Documentación: gasplus/docs/instalador-ubuntu.md.
#
# Opciones:
#   --codigo C        código de instalación del panel (o env GASPLUS_CODIGO)   [requerido]
#   --nombre N        nombre de la estación (p.ej. "Shell La Flecha")
#   --subdominio S    subdominio en gas.hn (p.ej. shelllaflecha → https://shelllaflecha.gas.hn)
#   --modo M          fusion (Gas+ factura) | alvic (terceros)                 [fusion]
#   --licencia L      clave GASPLUS-… si ya existe (si no, el panel la busca por URL)
#   --sin-zerotier    no unir a la red ZeroTier gas+ (soporte)
#   --sin-ufw         no tocar el firewall
#   --rustdesk        instalar RustDesk (soporte.gas.hn) — sólo útil con escritorio
#   --si / -y         no preguntar (usa lo pasado + defaults)
#   --kit P|URL       kit alternativo (pruebas); --kit-sha256 H para verificarlo
# =============================================================================
set -euo pipefail

KIT_SHA256="530c475108f1f1c3a68f3667d53e915d949fe01c3bc1840c946986ff53469ee8"          # lo sella station/build-kit.sh --publicar
KIT_VERSION="2026-09-30-098e4d8"
KIT_URL="https://gas.hn/gasplus-station-kit.tar.gz"
PANEL_URL="${GASPLUS_PANEL_URL:-https://panel.gas.hn}"
REGISTRY_HOST="registry.gas.hn"
ZT_NETWORK="f3797ba7a8173383"        # red "gas+" (soporte)
OPT=/opt/gasplus
GUSER=gas
LOG=/var/log/gasplus-install.log
# Llave PÚBLICA de soporte del T40 (station_ssh.sh / deploys / MCP). Pública: no es secreto.
T40_ADMIN_PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKciZ+FGSRsKwFw2znSVSohq08JiQSQ4+fbsz4Qw+4Rg t40-admin-gasplus 2026-09-20"

CODIGO="${GASPLUS_CODIGO:-}"; NOMBRE=""; SUB=""; MODO=""; LIC=""
ZT=1; UFW=1; RUSTDESK=0; YES=0; KIT_SRC=""; KIT_SHA_OVR=""
while [ $# -gt 0 ]; do case "$1" in
  --codigo) CODIGO="$2"; shift 2;; --nombre) NOMBRE="$2"; shift 2;;
  --subdominio) SUB="$2"; shift 2;; --modo) MODO="$2"; shift 2;; --licencia) LIC="$2"; shift 2;;
  --sin-zerotier) ZT=0; shift;; --sin-ufw) UFW=0; shift;; --rustdesk) RUSTDESK=1; shift;;
  --si|-y) YES=1; shift;; --kit) KIT_SRC="$2"; shift 2;; --kit-sha256) KIT_SHA_OVR="$2"; shift 2;;
  -h|--help) sed -n '2,40p' "$0" 2>/dev/null || true; exit 0;;
  *) echo "opción desconocida: $1 (ver --help)" >&2; exit 2;; esac; done

ok(){   printf '\033[32m✔ %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m⚠ %s\033[0m\n' "$*"; }
err(){  printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }
hdr(){  printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){  err "$*"; err "Instalación detenida. Log completo: $LOG"; exit 1; }
PEND=(); pend(){ PEND+=("$1"); }
CHK=();  chk(){ CHK+=("$1|$2|$3"); }     # estado|ítem|detalle

[ "$(id -u)" -eq 0 ] || { err "Debe correr como root:  curl -fsSL https://gas.hn/install-ubuntu.sh | sudo bash -s -- --codigo <CÓDIGO>"; exit 1; }
mkdir -p "$(dirname "$LOG")"; touch "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'err "Error inesperado en la línea $LINENO (comando: $BASH_COMMAND). Log: $LOG"' ERR
echo; echo "######## gas+ install-ubuntu $(date '+%F %T %z') kit=$KIT_VERSION ########"

TTY=/dev/tty; { : < "$TTY"; } 2>/dev/null || TTY=""
ask(){ # ask VAR "Pregunta" "default"
  local __v="$1" __q="$2" __d="${3:-}" __r=""
  if [ "$YES" = 1 ] || [ -z "$TTY" ]; then printf -v "$__v" '%s' "$__d"; return; fi
  read -r -p "$__q${__d:+ [$__d]}: " __r < "$TTY" || true
  printf -v "$__v" '%s' "${__r:-$__d}"
}

# =============================================================================
hdr "1/9 · Verificación previa"
. /etc/os-release 2>/dev/null || true
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:24.04|ubuntu:22.04) ok "SO: $PRETTY_NAME" ;;
  ubuntu:*) warn "SO: ${PRETTY_NAME:-?} — probado en 22.04/24.04; sigo." ;;
  *) die "Este instalador es para Ubuntu Server (detectado: ${PRETTY_NAME:-desconocido})." ;;
esac
[ "$(uname -m)" = x86_64 ] || die "Arquitectura $(uname -m) no soportada (la imagen Gas+ es amd64)."
RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if [ "$RAM_MB" -lt 3500 ]; then warn "RAM ${RAM_MB} MB (< 4 GB): el stack puede quedarse sin memoria."; else ok "RAM ${RAM_MB} MB"; fi
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
if [ "${DISK_GB:-0}" -lt 40 ]; then warn "Disco libre en /: ${DISK_GB} GB (mínimo 40, estándar 100 GB — §7.1)."; else ok "Disco libre en /: ${DISK_GB} GB"; fi
for u in "$PANEL_URL/" "https://$REGISTRY_HOST/v2/" "https://gas.hn/"; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$u" || echo 000)
  [ "$c" != 000 ] || die "Sin salida a $u (revisá DNS/internet/proxy)."
done
ok "Salida a internet (panel, registry, gas.hn)"

# Defaults: si ya hay una instalación, re-ejecutar reusa sus datos.
if [ -f "$OPT/.env" ]; then
  _g(){ { grep -E "^$1=" "$OPT/.env" || true; } | head -1 | cut -d= -f2-; }
  [ -n "$NOMBRE" ] || NOMBRE="$(_g GAS_SITE_NAME)"
  [ -n "$SUB" ]    || SUB="$(_g LICENSE_STATION_URL | sed -E 's#^https?://##')"
  [ -n "$MODO" ]   || MODO="$(_g GAS_SITE_MODE)"
  [ -n "$LIC" ]    || LIC="$(_g LICENSE_KEY)"
  ok "Instalación previa detectada en $OPT — se reusa (idempotente)."
fi
[ -n "$CODIGO" ] || ask CODIGO "Código de instalación del panel" ""
[ -n "$CODIGO" ] || die "Falta el código de instalación (--codigo). Pedilo al administrador del panel Gas+."
[ -n "$NOMBRE" ] || ask NOMBRE "Nombre de la estación" "$(hostname)"
_slug(){ echo "$1" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9'; }
[ -n "$SUB" ] || ask SUB "Subdominio (queda https://<subdominio>.gas.hn)" "$(_slug "$NOMBRE")"
SUB="$(echo "$SUB" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*$##; s#\.gas\.hn$##')"
echo "$SUB" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,40}[a-z0-9])?$' || die "Subdominio inválido: '$SUB' (solo a-z, 0-9 y guiones)."
[ -n "$MODO" ] || ask MODO "Modo (fusion = Gas+ factura · alvic = terceros)" "fusion"
MODO="$(echo "$MODO" | tr 'A-Z' 'a-z')"; case "$MODO" in fusion|alvic) ;; *) die "Modo inválido: $MODO (fusion|alvic)";; esac
FQDN="$SUB.gas.hn"
echo "  Estación: $NOMBRE · https://$FQDN · modo $MODO"

# =============================================================================
hdr "2/9 · Paquetes del sistema (Docker + compose, SSH, firewall)"
export DEBIAN_FRONTEND=noninteractive
need=()
for p in curl ca-certificates openssl python3 openssh-server ufw; do dpkg -s "$p" >/dev/null 2>&1 || need+=("$p"); done
if ! docker --version >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then need+=(docker.io docker-compose-v2); fi
if [ "${#need[@]}" -gt 0 ]; then
  apt-get update -y -qq
  apt-get install -y -qq "${need[@]}" || die "apt no pudo instalar: ${need[*]}"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
ok "$(docker --version) · $(docker compose version | head -1)"

# =============================================================================
hdr "3/9 · Kit de estación (mismo que la VHDX)"
TMPK="$(mktemp -d)"; trap 'rm -rf "$TMPK"' EXIT
SRC="${KIT_SRC:-$KIT_URL}"
case "$SRC" in http*://*) curl -fsSL --retry 3 -o "$TMPK/kit.tgz" "$SRC" || die "No pude bajar el kit ($SRC).";; *) cp "$SRC" "$TMPK/kit.tgz";; esac
WANT="${KIT_SHA_OVR:-$KIT_SHA256}"
GOT="$(sha256sum "$TMPK/kit.tgz" | awk '{print $1}')"
if ! echo "$WANT" | grep -Eq '^[0-9a-f]{64}$'; then   # sin sellar (corrido desde el repo)
  [ -n "$KIT_SRC" ] || die "Script sin sellar (falta el sha256 del kit). Bajalo de https://gas.hn/install-ubuntu.sh"
  warn "Kit local sin sha256 de referencia (modo prueba): $GOT"
elif [ "$GOT" != "$WANT" ]; then
  die "El kit NO coincide con el sha256 sellado (esperado $WANT, bajado $GOT). No se instala."
else ok "Kit verificado (sha256 ${GOT:0:16}…)"; fi
mkdir -p "$OPT"
# Se renuevan SOLO los archivos del kit; .env, override y datos de la estación se preservan.
rm -rf "$OPT/lib" "$OPT/etc" "$OPT/initdb"
tar -xzf "$TMPK/kit.tgz" -C "$OPT" --no-same-owner
install -m 644 "$OPT/etc/systemd/system/gasplus-firstboot.service" /etc/systemd/system/gasplus-firstboot.service
ok "Kit $(cat "$OPT/KIT_VERSION" 2>/dev/null) en $OPT"
# shellcheck disable=SC1091
. "$OPT/lib/gasplus-station.sh"

# =============================================================================
hdr "4/9 · Sistema: hora de Honduras + NTP, higiene, swap, usuario de soporte"
gp_hora; gp_higiene; gp_swap
journalctl --vacuum-size=200M >/dev/null 2>&1 || true
if ! id "$GUSER" &>/dev/null; then useradd -m -s /bin/bash "$GUSER"; ok "Usuario '$GUSER' creado"; fi
usermod -aG docker "$GUSER"
install -d -o "$GUSER" -g "$GUSER" -m 700 "/home/$GUSER/.ssh"
AK="/home/$GUSER/.ssh/authorized_keys"; touch "$AK"; chown "$GUSER:$GUSER" "$AK"; chmod 600 "$AK"
grep -qF "$(echo "$T40_ADMIN_PUB" | awk '{print $2}')" "$AK" || echo "$T40_ADMIN_PUB" >> "$AK"
ok "Hora: $(timedatectl show -p Timezone --value) · NTP $(grep -m1 '^NTP=' /etc/systemd/timesyncd.conf.d/gasplus.conf | cut -d= -f2) · llave de soporte del T40 sembrada"

# =============================================================================
hdr "5/9 · Alta en el panel (túnel Cloudflare + tokens)"
PROV="$TMPK/prov.env"
PANEL_URL="$PANEL_URL" CODIGO="$CODIGO" SUB="$FQDN" NOMBRE="$NOMBRE" LIC="$LIC" python3 - "$PROV" <<'PY' || die "El panel rechazó la provisión (ver arriba)."
import json, os, sys, time, urllib.request, urllib.error
body = json.dumps({"subdomain": os.environ["SUB"], "site_name": os.environ["NOMBRE"], "cliente": "",
                   "license_key": os.environ.get("LIC", ""), "create_tunnel": True}).encode()
last = ""
for i in range(4):
    req = urllib.request.Request(os.environ["PANEL_URL"] + "/api/provision-station", data=body, method="POST",
          headers={"Content-Type": "application/json", "X-Provision-Token": os.environ["CODIGO"],
                   "User-Agent": "gasplus-install-ubuntu"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: d = json.load(r); break
    except urllib.error.HTTPError as e:
        try: msg = json.load(e).get("error", "")
        except Exception: msg = ""
        if e.code == 403: print("✗ Código de instalación inválido."); sys.exit(1)
        last = "HTTP %s %s" % (e.code, msg)
    except Exception as e:
        last = str(e)
    time.sleep(5 * (i + 1))
else:
    print("✗ panel:", last); sys.exit(1)
if not d.get("ok") or not d.get("tunnel_token"):
    print("✗ el panel no devolvió túnel:", d.get("error") or d.get("tunnel_error")); sys.exit(1)
keys = {"STATION_ID": "station_id", "AGENT_TOKEN": "agent_token", "AGENT_INTERNAL_TOKEN": "internal_token",
        "TUNNEL_TOKEN": "tunnel_token", "LICENSE_KEY": "license_key", "UPDATE_KEY": "update_key",
        "REGISTRY_USER": "registry_user", "REGISTRY_PASS": "registry_pass", "AGENT_URL": "agent_url"}
with open(sys.argv[1], "w") as f:
    for k, j in keys.items():
        v = d.get(j)
        if v is not None: f.write("%s=%s\n" % (k, str(v).replace("\n", "")))
print("✔ estación #%s registrada en el panel (%s)" % (d.get("station_id"), d.get("url")))
PY
pv(){ { grep -E "^$1=" "$PROV" || true; } | head -1 | cut -d= -f2-; }
STATION_ID="$(pv STATION_ID)"
for k in AGENT_TOKEN AGENT_INTERNAL_TOKEN TUNNEL_TOKEN UPDATE_KEY REGISTRY_USER REGISTRY_PASS; do
  [ -n "$(pv $k)" ] || die "El panel no devolvió $k (revisá panel.env: CF_TOKEN, PORTAL_UPDATE_KEY, REGISTRY_USER/PASS)."
done
[ "$(pv REGISTRY_USER)" != gasplus ] || die "El panel entregó la credencial de PUSH del registry (gasplus). Una estación sólo lleva la de SOLO LECTURA (§3.3) — corregir REGISTRY_USER/PASS en panel.env."
ok "Tokens recibidos: túnel, agente, interno, update, registry (solo lectura: $(pv REGISTRY_USER))"

# =============================================================================
hdr "6/9 · Configuración de la estación (.env)"
# Espejo de Engine.cs::BuildEnv (g+ Installer). Se preservan las líneas de Fusion/ALVIC/EVO
# que ya se hayan cargado en una instalación previa.
KEEP=""; [ -f "$OPT/.env" ] && KEEP="$(grep -E '^(FUSION_|FB_ALVIC_|EVO_|ALVIC_SAR_|DISABLE_|DB_ROOT_PASS=)' "$OPT/.env" || true)"
LICK="$(pv LICENSE_KEY)"; [ -n "$LICK" ] || LICK="$LIC"
{
  echo "# .env generado por install-ubuntu.sh (Gas+ $KIT_VERSION) — $(date -Iseconds)"
  echo "TZ=America/Tegucigalpa"
  echo "GAS_SITE_NAME=$NOMBRE"
  echo "GAS_SITE_MODE=$MODO"
  if [ -n "$LICK" ]; then echo "LICENSE_KEY=$LICK"; fi
  echo "LICENSE_STATION_URL=https://$FQDN"
  echo "LICENSE_SERVER=https://licencia.gas.hn"
  echo "LICENSE_ENFORCE=hard"
  echo "LICENSE_PUBKEY=0Gr0LOsALApMP7qPwERUdeJzb9h8JIUVPJ9NF2Isve8="
  echo "LICENSE_LEASE_FILE=/lic/gasplus.lease"
  echo "LICENSE_KEY_FILE=/lic/license.key"
  echo "PISTA_DB_HOST=pos-gas-db"
  echo "PISTA_DB_USER=pos_gas"
  echo "PISTA_DB_PASSWORD=pos_gas_pass"
  echo "PISTA_DB_NAME=pos_gas"
  echo "DB_URL=mysql+pymysql://contab:contab_pass@pos-gas-db:3306/contab?charset=utf8mb4"
  echo "TUNNEL_TOKEN=$(pv TUNNEL_TOKEN)"
  echo "AGENT_TOKEN=$(pv AGENT_TOKEN)"
  echo "AGENT_INTERNAL_TOKEN=$(pv AGENT_INTERNAL_TOKEN)"
  echo "UPDATE_KEY=$(pv UPDATE_KEY)"
  echo "REGISTRY_USER=$(pv REGISTRY_USER)"
  echo "REGISTRY_PASS=$(pv REGISTRY_PASS)"
  if [ -n "$KEEP" ]; then echo "$KEEP"; fi
} > "$OPT/.env.new"
chown "root:$GUSER" "$OPT/.env.new"; chmod 640 "$OPT/.env.new"; mv -f "$OPT/.env.new" "$OPT/.env"
ok ".env escrito ($OPT/.env, 640 root:$GUSER)"

# =============================================================================
hdr "7/9 · Cadena de update firmada + imagen vigente (pull por digest)"
gp_cadena_update
# Si la credencial guardada quedó vieja (re-instalación), se re-siembra con la del panel.
. "/home/$GUSER/.registry-cred"
if ! echo "$REGISTRY_PASS" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin >/dev/null 2>&1; then
  { echo "REGISTRY_USER=$(pv REGISTRY_USER)"; echo "REGISTRY_PASS=$(pv REGISTRY_PASS)"; echo "REGISTRY_HOST=$REGISTRY_HOST"; } > "/home/$GUSER/.registry-cred"
  . "/home/$GUSER/.registry-cred"
  echo "$REGISTRY_PASS" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin >/dev/null || die "docker login $REGISTRY_HOST falló con la credencial del panel."
fi
ok "login en $REGISTRY_HOST (root) OK"
# Imagen pos-gas: con el MISMO update-gasplus v4 que usa el botón "Actualizar" → verifica la
# FIRMA Ed25519 del manifiesto del T40, baja por DIGEST, retaguea pos-gas:blindado y levanta.
UPD_OUT="$TMPK/upd.log"
if sudo -u "$GUSER" -H "/home/$GUSER/update-gasplus.sh" > "$UPD_OUT" 2>&1; then
  grep -E 'firma OK|version=|VERSION:|pista:|limpieza:|disco:' "$UPD_OUT" | sed 's/^/  /'
  ok "Imagen firmada aplicada"
else
  sed 's/^/  /' "$UPD_OUT" | tail -25; die "update-gasplus v4 falló (firma/registry). No se continúa con una imagen sin verificar."
fi
IMG_VER="$(sed -n 's/.*version=\([^ ]*\).*/\1/p' "$UPD_OUT" | head -1)"
docker pull -q "$REGISTRY_HOST/gasplus/agente:latest" >/dev/null || die "No pude bajar la imagen del agente (obligatorio, §3.2)."
docker tag "$REGISTRY_HOST/gasplus/agente:latest" gasplus-agente:latest
ok "Imagen del agente lista"
systemctl daemon-reload; systemctl enable gasplus-firstboot >/dev/null 2>&1
gp_stack_up
ok "Stack levantado (docker compose -p pos_gas)"

# =============================================================================
hdr "8/9 · Red: firewall, ZeroTier, RustDesk"
if [ "$UFW" = 1 ]; then
  ufw allow OpenSSH >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 5002/tcp >/dev/null; ufw allow 9993/udp >/dev/null
  ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null && ok "ufw activo: 22, 80, 5002 (Gas+ LAN), 9993/udp (ZeroTier)"
else warn "--sin-ufw: firewall sin tocar"; fi
ZT_ID=""
if [ "$ZT" = 1 ]; then
  command -v zerotier-cli >/dev/null 2>&1 || curl -fsSL https://install.zerotier.com | bash >/dev/null 2>&1 || warn "No pude instalar ZeroTier."
  if command -v zerotier-cli >/dev/null 2>&1; then
    systemctl enable --now zerotier-one >/dev/null 2>&1 || true; sleep 3
    zerotier-cli join "$ZT_NETWORK" >/dev/null 2>&1 || true
    ZT_ID="$(zerotier-cli info 2>/dev/null | awk '{print $3}')"
    ok "ZeroTier: miembro $ZT_ID unido a la red gas+ ($ZT_NETWORK)"
    zerotier-cli listnetworks 2>/dev/null | grep -q "$ZT_NETWORK.*OK" \
      || pend "Autorizar el miembro ZeroTier $ZT_ID en la red gas+ ($ZT_NETWORK) y anotar su IP 10.14.170.x."
  fi
else warn "--sin-zerotier: sin acceso de soporte por ZeroTier"; fi
if [ "$RUSTDESK" = 1 ]; then
  RD_VER="$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || echo 1.4.2)"
  if curl -fsSL -o "$TMPK/rustdesk.deb" "https://github.com/rustdesk/rustdesk/releases/download/$RD_VER/rustdesk-$RD_VER-x86_64.deb" \
     && apt-get install -y -qq "$TMPK/rustdesk.deb" >/dev/null 2>&1; then
    rustdesk --config "host=soporte.gas.hn,key=rwLCyTRWR5al5H1D07tByLIyJE1uZEVMOl2tkjUfgQg=,api=https://soporte.gas.hn:21114" >/dev/null 2>&1 || true
    ok "RustDesk $RD_VER instalado (servidor soporte.gas.hn). La clave fija se pone desde el panel → Herramientas."
  else warn "RustDesk no se pudo instalar (opcional)."; fi
fi

# =============================================================================
hdr "9/9 · Verificación (checklist §3.2)"
sleep 5
for c in pos-gas-db pos-gas agente cloudflared; do
  st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo ausente)"
  [ "$st" = running ] && chk OK "contenedor $c" running || chk FALLA "contenedor $c" "$st"
done
code=000; for i in $(seq 1 24); do code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1/pista/ || echo 000); case "$code" in 200|302) break;; esac; sleep 5; done
case "$code" in 200|302) chk OK "Gas+ local (http://127.0.0.1/pista/)" "HTTP $code";; *) chk FALLA "Gas+ local (http://127.0.0.1/pista/)" "HTTP $code";; esac
VER_RUN="$(docker exec pos-gas cat /app/VERSION 2>/dev/null || echo '?')"
[ -n "$IMG_VER" ] && [ "$VER_RUN" = "$IMG_VER" ] && chk OK "Versión = manifiesto firmado vigente" "$VER_RUN" || chk FALLA "Versión = manifiesto firmado vigente" "corre $VER_RUN / manifiesto ${IMG_VER:-?}"
TZC="$(docker exec pos-gas date +%z 2>/dev/null || echo '?')"; TZD="$(docker exec pos-gas-db date +%z 2>/dev/null || echo '?')"
SYNC="$(timedatectl show -p NTP --value 2>/dev/null)"
[ "$TZC" = -0600 ] && [ "$TZD" = -0600 ] && [ "$SYNC" = yes ] && chk OK "Hora Honduras + NTP (§25)" "app $TZC · db $TZD · NTP activo" || chk FALLA "Hora Honduras + NTP (§25)" "app $TZC · db $TZD · NTP=$SYNC"
IT="$(pv AGENT_INTERNAL_TOKEN)"
r="$(curl -s --max-time 20 -w '\n%{http_code}' -H "X-Internal-Token: $IT" http://127.0.0.1/pista/api/tanques/live || true)"
rc="$(echo "$r" | tail -1)"
if [ "$rc" = 200 ]; then chk OK "Token interno panel↔estación (tanques/precios)" "aceptado"
elif echo "$r" | grep -q 'No autenticado'; then chk FALLA "Token interno panel↔estación (tanques/precios)" "rechazado"
else chk AVISO "Token interno panel↔estación (tanques/precios)" "HTTP $rc — se verifica al asignar la licencia (candado duro)"; fi
AT="$(pv AGENT_TOKEN)"
h="$(docker exec agente python -c "import urllib.request as u;r=u.Request('http://127.0.0.1/health',headers={'X-Agent-Token':'$AT'});print(u.urlopen(r,timeout=10).status)" 2>/dev/null || echo err)"
[ "$h" = 200 ] && chk OK "Agente /health (local)" 200 || chk FALLA "Agente /health (local)" "$h"
docker exec agente test -r /agent-update/id_ed25519 && grep -q agent-update-firstboot "/home/$GUSER/.ssh/authorized_keys" && systemctl is-active --quiet ssh \
  && chk OK "Botón Actualizar (SSH restringido + v4 firmado)" "cableado" || chk FALLA "Botón Actualizar (SSH restringido + v4 firmado)" "incompleto"
pub=000; for i in $(seq 1 36); do pub=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$FQDN/pista/" || echo 000); case "$pub" in 200|302) break;; esac; sleep 5; done
case "$pub" in 200|302) chk OK "Túnel https://$FQDN" "HTTP $pub";; *) chk FALLA "Túnel https://$FQDN" "HTTP $pub (DNS/túnel tarda hasta unos minutos)";; esac
ag=000; for i in $(seq 1 24); do ag=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "X-Agent-Token: $AT" "https://$SUB-agente.gas.hn/health" || echo 000); [ "$ag" = 200 ] && break; sleep 5; done
[ "$ag" = 200 ] && chk OK "Agente por túnel https://$SUB-agente.gas.hn (panel: salud/respaldos/Fusion)" 200 || chk FALLA "Agente por túnel https://$SUB-agente.gas.hn" "HTTP $ag"
JU="$(du -sm /var/log/journal 2>/dev/null | awk '{print $1}')"
grep -q '"max-size": "10m"' /etc/docker/daemon.json && [ -s /etc/systemd/journald.conf.d/gasplus.conf ] \
  && chk OK "Higiene de disco (§7.1)" "journald 200M (${JU:-0} MB) · docker logs 10m×3" || chk FALLA "Higiene de disco (§7.1)" "incompleta"

pend "Desde el T40 (conector IA / MCP, §3.2): agregar la estación a scripts/ops/station_ssh.sh (_st_def) y a ESTACIONES de scripts/ops/provision_mcp.sh con panel_id $STATION_ID y subdominio $SUB, y correr: bash ~/gasplus/scripts/ops/provision_mcp.sh <ID>"
pend "Panel → Estaciones → #$STATION_ID: cargar vencimiento de soporte (sin soporte_vence el scheduler NO programa respaldos automáticos) y asignar la licencia si aún no tiene."
pend "Primer ingreso: https://$FQDN con admin / admin123 (obliga a cambiarla). Luego Configuración → Fusion/ALVIC (IP de la controladora) — la estación no comanda bombas hasta configurarla."
[ -n "$(pv LICENSE_KEY)$LIC" ] || pend "Licencia: la estación pedirá activación (/licencia) hasta asignarle una licencia GASPLUS en el panel."
pend "Agregar la línea de la estación (#$STATION_ID|$NOMBRE|https://$SUB-agente.gas.hn|<agent_token>) a ~/.credentials/gasplus-agents.txt del T40 para que reciba los deploys (scripts/ops/deploy_estaciones.sh)."

# =============================================================================
IP_LAN="$(hostname -I 2>/dev/null | awk '{print $1}')"
hdr "Resumen"
cat <<EOF
  Estación ........ $NOMBRE  (panel #$STATION_ID, modo $MODO)
  Versión Gas+ .... $VER_RUN   (kit $(cat "$OPT/KIT_VERSION" 2>/dev/null))
  Web pública ..... https://$FQDN
  Agente .......... https://$SUB-agente.gas.hn  (lo usa el panel)
  LAN ............. http://$IP_LAN   (también :5002)
  Usuario inicial . admin / admin123  (se obliga a cambiarla al entrar)
  Soporte SSH ..... gas@$IP_LAN (solo llave del T40)${ZT_ID:+ · ZeroTier $ZT_ID}
  Log ............. $LOG
EOF
echo; echo "  Checklist:"
FALLAS=0
for c in "${CHK[@]}"; do IFS='|' read -r s i d <<<"$c"
  if [ "$s" = OK ]; then printf '   \033[32m✔\033[0m %s — %s\n' "$i" "$d"
  elif [ "$s" = AVISO ]; then printf '   \033[33m⚠\033[0m %s — %s\n' "$i" "$d"; else printf '   \033[31m✗\033[0m %s — %s\n' "$i" "$d"; FALLAS=$((FALLAS+1)); fi; done
if [ "${#PEND[@]}" -gt 0 ]; then echo; echo "  Pendientes (fuera de esta máquina):"; n=1; for p in "${PEND[@]}"; do echo "   $n) $p"; n=$((n+1)); done; fi
echo
if [ "$FALLAS" -eq 0 ]; then ok "Estación Gas+ instalada. Re-ejecutar este comando es seguro (idempotente)."
else err "$FALLAS verificación(es) fallaron — revisá el log y re-ejecutá el comando (idempotente)."; exit 3; fi

#!/bin/bash
# Genera el dashboard de DEMO que se ve en el README (stats.png) con datos INVENTADOS:
# ningun hostname, IP, servicio ni disco real. Se renderiza con las funciones reales de
# stats.sh (colores, barras, wrap), asi que la imagen refleja el layout verdadero.
#
#   ./test/demo_dashboard.sh > /tmp/demo.txt
#   ./test/render_png.py /tmp/demo.txt stats.png
#
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB=$(mktemp) || exit 1
sed '$d' "$ROOT/stats.sh" >"$LIB"   # sin la ultima linea (collect_data + dispatch)
# shellcheck disable=SC1090
source "$LIB"
trap 'rm -f "$LIB"' EXIT

WIDTH=80
init_colors

# --- sistema (ficticio) ---
HOSTNAME="srv-prod-01"
OS="Debian GNU/Linux 12"
VERSION="Linux 6.1.0-13-amd64"
FECINS="2021-03-14"
ANTIGUEDAD="5y"
LAST_REBOOT="2026-09-02 04:12"
UPTIME="15d 3h 27m"

# --- hardware (ficticio) ---
PROC="Intel Xeon Silver 4314"
MHZ="2400"
CORES=16
CPU_USAGE_PERC=23.4
IOWAIT_PERC=0.8
LOAD="1.42"
PS_COUNT=412
MEMTOTAL=32094
MEMFREE=18422          # disponible
MEM_PERC=43
USERS=3

# --- estado ---
FAILED_SERVICES_COUNT=0
FAILED_SERVICES_LIST=""
TOP_RAM_LIST="postgres, nginx, node"
TOP_CPU_LIST="node, postgres, python3"

# --- red ---
IFACE="eth0"
IP="10.20.30.40/24"
RX_HUMAN="412.77 GiB"
TX_HUMAN="98.13 GiB"
CONEXIONES=87
RX_ERRS=0
TX_ERRS=0

# --- versiones y discos ---
DISTRO_NAME="Debian GNU/Linux"
DISTRO_VER="12"
SERVICE_VERSIONS='nginx:1.24.0
postgresql:16.3
redis:7.2.4'

DISCOS_DATA='/data:94:2.7T:161G
/var/lib/pgsql:43:917G:523G
/:62:219G:83G
/boot:16:1022M:863M'

SERVICES='docker-proxy:80,443,5432,6379
nginx:80,443
node:3000
postgresql:5432
redis:6379
sshd:22
smtpd:25,587
domain:53
prometheus:9090
grafana:3001'

LIMITE_PROC=300
LIMITE_CONX=200

render_dashboard
exit 0

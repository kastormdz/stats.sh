#!/bin/bash
#
# stats.sh - Sistema de monitoreo ligero para servidores Linux
# Autor: Cristian Gimenez <cgimenez@gmail.com>
#

# --- CONFIGURACIÓN Y VALORES POR DEFECTO ---
WIDTH=80
ANSIBLE=0
JSON=0
COLOR=1
VERBOSE=0
LIMITE_PROC=300
LIMITE_CONX=200

log_debug() { [ "$VERBOSE" -eq 1 ] && echo "[DEBUG] $*" >&2; }

# Colores (se inicializan solo si COLOR=1)
init_colors() {
  if [ "$COLOR" -eq 1 ]; then
    VERDE='\033[0;32m'
    ROJO='\033[0;31m'
    BOLD='\033[1m'
    AZUL='\033[0;34m'
    BLANCO='\033[0;37m'
    NC='\033[0m'
  else
    VERDE='' ROJO='' BOLD='' AZUL='' BLANCO='' NC=''
  fi
}

# Helper: eliminar secuencias ANSI para contar caracteres visibles
strip_ansi() {
  printf '%b' "$1" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g; s/\033([a-zA-Z]//g'
}

# --- MANEJO DE ARGUMENTOS ---
usage() {
  echo "Uso: $0 [OPCIONES]"
  echo "Opciones:"
  echo "  -a, --ansible    Modo compatible con Ansible (output simple)"
  echo "  -j, --json       Salida en formato JSON"
  echo "  -n, --no-color   Desactivar colores"
  echo "  -w, --width N    Ajustar ancho del recuadro (40-200, default: 80)"
  echo "  -v, --verbose    Mostrar información de depuración"
  echo "  -h, --help       Mostrar esta ayuda"
  exit 0
}

while [[ "$#" -gt 0 ]]; do
  case $1 in
  -a | --ansible | 1 | ansible | ANSIBLE)
    ANSIBLE=1
    shift
    ;;
  -j | --json)
    JSON=1
    shift
    ;;
  -n | --no-color)
    COLOR=0
    shift
    ;;
  -v | --verbose)
    VERBOSE=1
    shift
    ;;
  -w | --width)
    if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 40 ] && [ "$2" -le 200 ]; then
      WIDTH="$2"
      shift 2
    else
      echo "Error: --width debe ser un número entre 40 y 200" >&2
      exit 1
    fi
    ;;
  -h | --help) usage ;;
  *)
    echo "Opción desconocida: $1"
    usage
    ;;
  esac
done

init_colors

# --- FUNCIONES DE RECOLECCIÓN ---

get_service_version() {
  local cmd="$1"
  local bin

  # --- EXCEPCIÓN POSTFIX (proceso master) ---
  if [ "$cmd" = "master" ] || [ "$cmd" = "Postfix" ]; then
    if command -v postconf >/dev/null 2>&1; then
      local v
      v=$(postconf -d mail_version 2>/dev/null | cut -d= -f2 | xargs)
      [ -n "$v" ] && {
        echo "$v"
        return 0
      }
    fi
  fi

  bin=$(command -v "$cmd" 2>/dev/null)
  [ -z "$bin" ] && [ "$cmd" != "java" ] && return 1

  local ver=""

  # --- EXCEPCIÓN JAVA/TOMCAT ---
  if [ "$cmd" = "java" ] || [ "$cmd" = "Tomcat" ]; then
    if command -v tomcat >/dev/null 2>&1; then
      ver=$(tomcat version 2>/dev/null | grep "Server number" | cut -d: -f2 | xargs)
      [ -n "$ver" ] && {
        echo "$ver"
        return 0
      }
    fi
    # Usar cache global si está disponible (seteada en collect_data)
    local t_home="${TOMCAT_HOME:-}"
    if [ -z "$t_home" ]; then
      t_home=$(ps -ef | grep java | grep -E "Dcatalina\.(home|base)=" | grep -v grep | sed -E 's/.*Dcatalina\.(home|base)=([^ ]+).*/\2/' | head -n1)
    fi
    if [ -n "$t_home" ] && [ -d "$t_home" ]; then
      local t_jar="$t_home/lib/catalina.jar"
      [ ! -f "$t_jar" ] && t_jar=$(find "$t_home" -maxdepth 3 -name "catalina.jar" 2>/dev/null | head -n1)
      if [ -f "$t_jar" ]; then
        ver=$("${bin:-java}" -cp "$t_jar" org.apache.catalina.util.ServerInfo 2>/dev/null | grep "Server number" | cut -d: -f2 | xargs)
        [ -n "$ver" ] && {
          echo "$ver"
          return 0
        }
      fi
    fi
  fi

  # Fallback a gestores de paquetes si no es Tomcat/Postfix o si éstos fallaron
  [ -z "$bin" ] && return 1

  # Intentar con gestores de paquetes primero
  if command -v dpkg-query >/dev/null 2>&1; then
    local pkg
    pkg=$(dpkg-query -S "$bin" 2>/dev/null | awk -F: '{print $1}' | head -n1)
    if [ -n "$pkg" ]; then
      ver=$(dpkg-query -W -f='${Version}\n' "$pkg" 2>/dev/null)
    fi
  elif command -v rpm >/dev/null 2>&1; then
    # rpm -qf devuelve error a stderr si no encuentra el paquete, lo silenciamos
    ver=$(rpm -qf --qf '%{VERSION}\n' "$bin" 2>/dev/null | head -n1)
  elif command -v pacman >/dev/null 2>&1; then
    ver=$(pacman -Qo "$bin" 2>/dev/null | awk '{print $NF}')
  fi

  # Fallback a ejecución directa si el gestor falló o el archivo no pertenece a un paquete
  if [ -z "$ver" ] || [[ "$ver" == *"not owned"* ]] || [[ "$ver" == *"no package"* ]]; then
    if [ "$cmd" = "java" ]; then
      # Java usa -version en lugar de -v
      ver=$("$bin" -version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    else
      ver=$("$bin" -v 2>&1 || "$bin" --version 2>&1 || "$bin" -V 2>&1)
      ver=$(echo "$ver" | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    fi
  fi

  if [ -n "$ver" ]; then
    # Limpiamos epoch de Debian/Ubuntu (ej: "1:1.18.0" -> "1.18.0")
    echo "$ver" | sed -E 's/^[0-9]+://'
  else
    echo "N/A"
  fi
}

detect_install_date() {
  if [ -f /var/lib/cloud/instance/boot-finished ]; then
    stat -c %y /var/lib/cloud/instance/boot-finished 2>/dev/null | cut -d' ' -f1
    return
  fi
  if [ -f /var/log/cloud-init.log ]; then
    head -n1 /var/log/cloud-init.log 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}'
    return
  fi
  if [ -f /root/anaconda-ks.cfg ]; then
    stat -c %y /root/anaconda-ks.cfg 2>/dev/null | cut -d' ' -f1
    return
  fi
  if [ -f /var/log/pacman.log ]; then
    head -n1 /var/log/pacman.log 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1
    return
  fi
  local rpm_date
  rpm_date=$(LC_ALL=C rpm -q --qf '%{INSTALLTIME:date}\n' basesystem 2>/dev/null | awk '{print $4"-"$3"-"$2}' | sed 's/Jan/01/;s/Feb/02/;s/Mar/03/;s/Apr/04/;s/May/05/;s/Jun/06/;s/Jul/07/;s/Aug/08/;s/Sep/09/;s/Oct/10/;s/Nov/11/;s/Dec/12/')
  if [ -n "$rpm_date" ]; then
    echo "$rpm_date"
    return
  fi
  if [ -d /var/log/installer ]; then
    stat -c %y /var/log/installer 2>/dev/null | cut -d' ' -f1
    return
  fi
  ls -lct --time-style=long-iso /etc 2>/dev/null | tail -1 | awk '{print $6}'
}

collect_system_info() {
  HOSTNAME=$(hostname)
  OS=$(grep PRETTY /etc/os-release 2>/dev/null | cut -d= -f2 | sed 's/\"//g')
  [ -z "$OS" ] && OS=$(cat /etc/redhat-release 2>/dev/null || cat /etc/centos-release 2>/dev/null || cat /etc/system-release 2>/dev/null || echo "Unknown")
  VERSION=$(uname -sr)
  UPTIME_S=$(awk '{print int($1)}' /proc/uptime)
  UPTIME_D=$((UPTIME_S / 86400))
  UPTIME_H=$((UPTIME_S % 86400 / 3600))
  UPTIME_M=$((UPTIME_S % 3600 / 60))
  UPTIME="${UPTIME_D}d ${UPTIME_H}h ${UPTIME_M}m"
  LAST_REBOOT=$( (uptime -s 2>/dev/null | cut -d: -f1,2 || who -b | awk '{print $3,$4}') | xargs)
  USERS=$(uptime | grep -oE '[0-9]+ user' | grep -oE '[0-9]+' | head -n1 || echo "0")
  INSTALADO=$(detect_install_date)
  FECINS=$(echo "$INSTALADO" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1)
  ACTUAL_DATE=$(date +%Y-%m-%d)
  ANTIGUEDAD=$(awk -v d1="$FECINS" -v d2="$ACTUAL_DATE" 'BEGIN {
      split(d1, a, "-"); split(d2, b, "-");
      y = b[1] - a[1]; m = b[2] - a[2];
      if (b[3] < a[3]) m--;
      if (m < 0) { y--; m += 12; }
      if (y > 0) printf "%da", y;
      else printf "%dm", m;
  }')
}

collect_cpu_info() {
  local cpuinfo_arr
  mapfile -t cpuinfo_arr < <(awk '/model name/ {sub(/.*: /,""); p=$0} /cpu MHz/ {sub(/.*: /,""); sub(/\..*/,""); m=$0} END {print p; print m}' /proc/cpuinfo)
  PROC="${cpuinfo_arr[0]}"
  MHZ="${cpuinfo_arr[1]}"
  CORES=$(nproc 2>/dev/null)
  [ -z "$CORES" ] && CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
  [ -z "$CORES" ] && CORES=1
  [ "$CORES" -lt 1 ] && CORES=1
  LOAD=$(awk '{print $1}' /proc/loadavg)
  PS_COUNT=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
}

collect_memory_info() {
  read -r MEMTOTAL MEMUSED MEMFREE <<<"$(free -m | grep Mem: | awk '{print $2, $3, $4}')"
  if [ -n "$MEMTOTAL" ] && [ "$MEMTOTAL" -gt 0 ] 2>/dev/null; then
    MEM_PERC=$((MEMUSED * 100 / MEMTOTAL))
  else
    MEM_PERC=0
  fi
}

collect_network_info() {
  read -r IFACE IP <<<"$(ip -4 addr show | awk '/inet / && !/127.0.0.1/ {print $NF, $2; exit}')"
  if [ -n "$IFACE" ]; then
    IFACE_CLEAN=$(echo "$IFACE" | tr -d ':')
    read -r RX_BYTES TX_BYTES RX_ERRS TX_ERRS <<< \
      "$(awk -v iface="$IFACE_CLEAN" '$0 ~ iface {gsub(/:/," "); print $2, $10, $4, $12}' /proc/net/dev)"
    RX_HUMAN=$(awk -v b="$RX_BYTES" "BEGIN { if (b>1024*1024*1024) printf \"%.2f GB\", b/1024/1024/1024; else printf \"%.2f MB\", b/1024/1024 }")
    TX_HUMAN=$(awk -v b="$TX_BYTES" "BEGIN { if (b>1024*1024*1024) printf \"%.2f GB\", b/1024/1024/1024; else printf \"%.2f MB\", b/1024/1024 }")
    if command -v ss >/dev/null 2>&1; then
      # Contamos conexiones establecidas y en estados activos (SYN_SENT, FIN_WAIT, etc)
      CONEXIONES=$(ss -tun | grep -vE '^Netid|^State|LISTEN' | wc -l)
    else
      CONEXIONES=$(netstat -tun | grep -vE '^Active|Proto|LISTEN' | wc -l)
    fi
  fi
}

collect_data() {
  collect_system_info
  collect_cpu_info
  collect_memory_info
  collect_network_info
  CONEXIONES=${CONEXIONES:-0}
  RX_ERRS=${RX_ERRS:-0}
  TX_ERRS=${TX_ERRS:-0}

  log_debug "CPU: $PROC | Cores: $CORES | Load: $LOAD"
  log_debug "Memory: ${MEMTOTAL:-0}MB total, ${MEM_PERC:-0}% used"
  log_debug "Network: ${IFACE:-none} @ ${IP:-none}"
  log_debug "Install date: ${FECINS:-unknown} (${ANTIGUEDAD:-unknown})"

  CPU_1=$(head -n1 /proc/stat)
  STATS_TMPDIR=$(mktemp -d)
  trap 'rm -rf "$STATS_TMPDIR" 2>/dev/null; [ -t 1 ] && tput cnorm 2>/dev/null; echo' EXIT INT TERM

  # Cachear detección de Tomcat para evitar múltiples ps+grep
  TOMCAT_HOME=$(ps -ef | grep java | grep -E "Dcatalina\.(home|base)=" | grep -v grep | sed -E 's/.*Dcatalina\.(home|base)=([^ ]+).*/\2/' | head -n1)
  export TOMCAT_HOME

  {
    ss -plunt 2>/dev/null | awk '
      BEGIN { while ((getline < "/etc/services") > 0) { if ($2 ~ /\//) { split($2, p, "/"); if (!(p[1] in svc_map)) svc_map[p[1]] = $1; } } }
      NR>1 { 
          split($5, a, ":"); port=a[length(a)]; 
          # Intentar extraer nombre del proceso de ss
          name="unknown";
          if (match($0, /"([^"]+)"/, m)) name=m[1];
          else if (port in svc_map) name=svc_map[port];
          
          if (!(name "_" port in seen)) { 
              services[name] = (services[name] ? services[name] "," port : port); 
              seen[name "_" port] = 1 
          }
      } END { for (s in services) print s ":" services[s]; }' | sort -u >"$STATS_TMPDIR/services"

    while read -r line; do
      [ -z "$line" ] && continue
      svc_name=$(echo "$line" | cut -d: -f1)
      svc_ports=$(echo "$line" | cut -d: -f2)
      [ "$svc_name" = "unknown" ] && continue

      # Obtener versión y manejar excepciones de renombramiento
      svc_ver=$(get_service_version "$svc_name")

      # Si es java y detectamos Tomcat, renombramos el servicio
      if [ "$svc_name" = "java" ]; then
        if [ -n "$TOMCAT_HOME" ] || command -v tomcat >/dev/null 2>&1; then
          svc_name="Tomcat"
        fi
      fi

      # Si es el proceso master, renombramos a Postfix
      if [ "$svc_name" = "master" ]; then
        svc_name="Postfix"
      fi

      # Guardar puerto con el nuevo nombre si es necesario
      echo "$svc_name:$svc_ports" >>"$STATS_TMPDIR/services_new"
      [ -n "$svc_ver" ] && echo "$svc_name:$svc_ver" >>"$STATS_TMPDIR/service_versions"
    done <"$STATS_TMPDIR/services"
    mv "$STATS_TMPDIR/services_new" "$STATS_TMPDIR/services"
  } &
  (df -P -h | grep -vE 'tmpfs|none|udev|shm|loop|efivarfs|overlay|nsfs' | awk 'NR>1 {print $6 ":" $5 ":" $2 ":" $4}' | tr -d '%' >"$STATS_TMPDIR/discos") &
  (ps -eo comm --sort=-%mem | awk 'NR>1 && NR<=4 {printf "%s%s", sep, $1; sep=", "}' >"$STATS_TMPDIR/ram") &
  (ps -eo comm --sort=-%cpu | awk 'NR>1 && NR<=4 {printf "%s%s", sep, $1; sep=", "}' >"$STATS_TMPDIR/cpu_top") &

  sleep 0.5
  CPU_2=$(head -n1 /proc/stat)
  wait
  SERVICES=$(cat "$STATS_TMPDIR/services")
  SERVICE_VERSIONS=$([ -f "$STATS_TMPDIR/service_versions" ] && cat "$STATS_TMPDIR/service_versions" | sort -u)
  TOP_RAM_LIST=$(cat "$STATS_TMPDIR/ram")
  TOP_CPU_LIST=$(cat "$STATS_TMPDIR/cpu_top")
  DISCOS_DATA=$(cat "$STATS_TMPDIR/discos")

  if command -v systemctl >/dev/null 2>&1; then
    FAILED_SERVICES_LIST=$(systemctl list-units --failed --type=service --no-legend --no-pager | awk '{for(i=1;i<=NF;i++) if($i~/\.service/) print $i}')
    FAILED_SERVICES_COUNT=$(echo "$FAILED_SERVICES_LIST" | grep -v "^$" | wc -l)
  elif command -v rc-status >/dev/null 2>&1; then
    FAILED_SERVICES_LIST=$(rc-status --crashed | awk '{print $1}')
    FAILED_SERVICES_COUNT=$(echo "$FAILED_SERVICES_LIST" | grep -v "^$" | wc -l)
  else
    FAILED_SERVICES_LIST=""
    FAILED_SERVICES_COUNT=0
  fi

  # Cálculo final de CPU (Uso e I/O Wait)
  read -r CPU_USAGE_PERC IOWAIT_PERC <<<"$(printf "%s\n%s" "$CPU_1" "$CPU_2" | awk '{
      t=0; for(j=2;j<=NF;j++) t+=$j; u[NR]=t; idl[NR]=$5; wai[NR]=$6;
  } END {
      diff_t=u[2]-u[1]; 
      diff_i=(idl[2]+wai[2])-(idl[1]+wai[1]);
      diff_w=wai[2]-wai[1];
      if(diff_t>0) { 
          usage=100*(diff_t-diff_i)/diff_t; 
          iowait=100*diff_w/diff_t;
          if(usage<0) usage=0; if(usage>100) usage=100; 
          if(iowait<0) iowait=0; if(iowait>100) iowait=100;
          printf "%.1f %.1f", usage, iowait; 
      } else print "0 0";
  }')"
}

# --- FUNCIONES VISUALES ---

draw_line() {
  local text="$1"
  local target_visible=$((WIDTH - 4))
  local clean
  clean=$(strip_ansi "$text")

  # Conteo robusto: reemplazamos caracteres multibyte conocidos por 'X' para contar columnas
  local count_str
  count_str=$(echo -n "$clean" | sed 's/█/X/g; s/░/X/g; s/─/X/g; s/│/X/g')
  local len=${#count_str}

  local padding=$((target_visible - len))
  if [ "$padding" -lt 0 ]; then
    echo -e "│ $text │"
  else
    local spacer=$(printf "%${padding}s" "")
    echo -e "│ $text$spacer │"
  fi
}

draw_bar() {
  local percent=${1:-0}
  # Asegurar que percent sea un número entero
  if ! [[ "$percent" =~ ^[0-9]+$ ]]; then
    percent=0
  fi
  local bar_size=15
  local filled=$((percent * bar_size / 100))
  [ "$filled" -gt "$bar_size" ] && filled=$bar_size
  local empty=$((bar_size - filled))
  local color=$VERDE
  [ "$percent" -gt 70 ] && color=$AZUL
  [ "$percent" -gt 90 ] && color=$ROJO

  local bar_filled="" bar_empty=""
  if [ "$filled" -gt 0 ]; then
    printf -v bar_filled '%*s' "$filled" ''
    bar_filled=${bar_filled// /█}
  fi
  if [ "$empty" -gt 0 ]; then
    printf -v bar_empty '%*s' "$empty" ''
    bar_empty=${bar_empty// /░}
  fi
  printf "[%s%s%s] %3d%%" "${color}${bar_filled}" "${BLANCO}${bar_empty}" "${NC}" "$percent"
}

# Helper para padding basado en caracteres (no bytes)
pad_label() {
  local text="$1"
  local width="$2"
  local clean
  clean=$(strip_ansi "$text")

  local count_str
  count_str=$(echo -n "$clean" | sed 's/█/X/g; s/░/X/g')
  local len=${#count_str}

  local pad=$((width - len))
  [ "$pad" -lt 0 ] && pad=0
  local spacer=$(printf "%${pad}s" "")
  echo -n "$text$spacer"
}

render_dashboard() {
  [ -t 1 ] && tput civis
  local H_LINE=""
  for ((i = 0; i < WIDTH - 2; i++)); do H_LINE+="─"; done
  echo -e "┌${H_LINE}┐"
  draw_line "${BOLD}[SISTEMA]${NC}"
  draw_line "Hostname: ${VERDE}$HOSTNAME${NC}"
  draw_line "OS: ${AZUL}$OS${NC} ($VERSION)"
  draw_line "Inst.: $FECINS ($ANTIGUEDAD) | Boot: ${AZUL}$LAST_REBOOT${NC}"
  draw_line "Uptime: ${AZUL}$UPTIME${NC}"
  echo -e "├${H_LINE}┤"
  draw_line "${BOLD}[HARDWARE]${NC}"
  draw_line "CPU: $PROC @ $MHZ Mhz"
  draw_line "$(pad_label "Uso CPU" 25) $(draw_bar ${CPU_USAGE_PERC%.*}) | Cores: ${AZUL}$CORES${NC}"
  local LOAD_PERC=$(awk -v l="$LOAD" -v c="$CORES" "BEGIN { p=(l*100)/c; if(p>100) p=100; print int(p) }")
  draw_line "$(pad_label "Carga (Load $LOAD)" 25) $(draw_bar $LOAD_PERC) | Procs: ${AZUL}$PS_COUNT${NC}"
  draw_line "$(pad_label "Memoria RAM" 25) $(draw_bar $MEM_PERC) | T: ${MEMTOTAL}Mb L: ${MEMFREE}Mb"
  draw_line "$(pad_label "I/O Wait (Disco)" 25) $(draw_bar ${IOWAIT_PERC%.*})"
  draw_line "Usuarios Logueados: ${AZUL}$USERS${NC}"
  echo -e "├${H_LINE}┤"
  draw_line "${BOLD}[ESTADO]${NC}"
  local S_COLOR=$VERDE
  [ "$FAILED_SERVICES_COUNT" -gt 0 ] && S_COLOR=$ROJO
  draw_line "Servicios Fallidos: ${S_COLOR}$FAILED_SERVICES_COUNT${NC}"
  if [ "$FAILED_SERVICES_COUNT" -gt 0 ]; then
    while read -r s; do [ -n "$s" ] && draw_line "  - ${ROJO}$s${NC}"; done <<<"$FAILED_SERVICES_LIST"
  fi
  draw_line "Top RAM: ${AZUL}$TOP_RAM_LIST${NC}"
  draw_line "Top CPU: ${AZUL}$TOP_CPU_LIST${NC}"
  if [ -n "$IFACE" ]; then
    echo -e "├${H_LINE}┤"
    draw_line "${BOLD}[RED]${NC}"
    draw_line "Placa: ${AZUL}$IFACE${NC} @ ${AZUL}$IP${NC}"
    draw_line "Recibido: ${VERDE}$RX_HUMAN${NC} | Enviado: ${VERDE}$TX_HUMAN${NC}"
    draw_line "Conexiones: ${AZUL}$CONEXIONES${NC} | Errores: ${ROJO}RX: $RX_ERRS / TX: $TX_ERRS${NC}"
  fi
  echo -e "├${H_LINE}┤"
  draw_line "${BOLD}[ALMACENAMIENTO]${NC}"
  while read -r d; do
    [ -z "$d" ] && continue
    IFS=: read -r mount perc total free <<<"$d"
    if [ "${#mount}" -gt 25 ]; then mount="${mount:0:11}...${mount: -11}"; fi
    draw_line "$(pad_label "$mount" 25) $(draw_bar "$perc") | T: ${total} L: ${free}"
  done <<<"$DISCOS_DATA"
  echo -e "├${H_LINE}┤"
  draw_line "${BOLD}[SERVICIOS]${NC}"
  local svc_indent=2
  local svc_name_col=22
  local svc_cont_pad=$(printf "%$((svc_indent + svc_name_col))s" "")
  while read -r s; do
    [ -z "$s" ] && continue
    IFS=: read -r name ports <<<"$s"
    local name_vis_len
    name_vis_len=$(echo -n "$name" | wc -L 2>/dev/null || echo -n "$name" | wc -m)
    local padding_count=$((svc_name_col - name_vis_len))
    [ "$padding_count" -lt 0 ] && padding_count=0
    local name_colored="${VERDE}$name${NC}"
    local padding_spaces=$(printf "%${padding_count}s" "")
    local prefix="  $name_colored$padding_spaces"
    local prefix_vis=$((svc_indent + svc_name_col))

    local current_line="$prefix"
    local current_vis=$prefix_vis
    IFS=',' read -ra ADDR <<<"$ports"
    for port in "${ADDR[@]}"; do
      local port_trimmed
      port_trimmed=$(echo "$port" | tr -d ' ')
      local add_len
      if [[ "$current_line" == "$prefix" ]] || [[ "$current_line" =~ ^[[:space:]]+$ ]]; then
        add_len=${#port_trimmed}
      else
        add_len=$((${#port_trimmed} + 2))
      fi
      if [ $((current_vis + add_len)) -gt $((WIDTH - 4)) ]; then
        draw_line "$current_line"
        current_line="${svc_cont_pad}${port_trimmed}"
        current_vis=$((prefix_vis + ${#port_trimmed}))
      elif [[ "$current_line" == "$prefix" ]] || [[ "$current_line" =~ ^[[:space:]]+$ ]]; then
        current_line+="$port_trimmed"
        current_vis=$((current_vis + ${#port_trimmed}))
      else
        current_line+=", $port_trimmed"
        current_vis=$((current_vis + ${#port_trimmed} + 2))
      fi
    done
    [ -n "$current_line" ] && draw_line "$current_line"
  done <<<"$SERVICES"

  echo -e "├${H_LINE}┤"
  draw_line "${BOLD}[VERSIONES]${NC}"
  # Versión de la Distribución (OS) desde NAME y VERSION
  local d_name
  d_name=$(grep '^NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  [ -z "$d_name" ] && d_name=$(cat /etc/redhat-release 2>/dev/null | awk '{print $1}' || echo "Unknown")
  local d_ver
  d_ver=$(grep '^VERSION=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | awk '{print $1}')
  [ -z "$d_ver" ] && d_ver=$(cat /etc/redhat-release 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo "Rolling")

  # Preparar lista de versiones (Distro + Servicios) - Usamos coma como único separador para el split
  local ver_output="$d_name:$d_ver"
  if [ -n "$SERVICE_VERSIONS" ]; then
    while read -r sv; do
      [ -n "$sv" ] && ver_output+=",$sv"
    done <<<"$SERVICE_VERSIONS"
  fi

  # Renderizar versiones con wrapping
  local current_ver_line="  "
  local current_ver_vis=2
  IFS=',' read -ra V_ADDR <<<"$ver_output"
  for v_pair in "${V_ADDR[@]}"; do
    [ -z "$v_pair" ] && continue
    # Usamos parameter expansion para separar por el primer ':'
    local v_name="${v_pair%%:*}"
    local v_val="${v_pair#*:}"

    local v_str="${VERDE}$v_name${NC}:${BLANCO}$v_val${NC}"
    # Calculamos longitud visible (nombre + valor + separador ':')
    local v_len=$((${#v_name} + ${#v_val} + 1))

    if [ $((current_ver_vis + v_len + 2)) -gt $((WIDTH - 4)) ]; then
      draw_line "$current_ver_line"
      current_ver_line="  $v_str"
      current_ver_vis=$((2 + v_len))
    else
      if [ "$current_ver_line" = "  " ]; then
        current_ver_line+="$v_str"
        current_ver_vis=$((current_ver_vis + v_len))
      else
        current_ver_line+="${BLANCO}, ${NC}$v_str"
        current_ver_vis=$((current_ver_vis + v_len + 2))
      fi
    fi
  done
  [ -n "$current_ver_line" ] && draw_line "$current_ver_line"

  echo -e "└${H_LINE}┘"

  # ALERTAS (solo en modo visual, fuera del recuadro)
  while read -r d; do
    [ -z "$d" ] && continue
    IFS=: read -r mount perc _rest <<<"$d"
    if [[ "$perc" =~ ^[0-9]+$ ]] && [ "$perc" -gt 90 ]; then
      echo -e "  ${ROJO}${BOLD}WARNING:${NC} FS $mount al $perc% usado!"
    fi
  done <<<"$DISCOS_DATA"
  if [ -n "$LOAD" ] && awk -v v_load="$LOAD" -v cores="$CORES" 'BEGIN {exit !(v_load >= cores && v_load >= 1.0)}' 2>/dev/null; then
    echo -e "  ${ROJO}${BOLD}WARNING:${NC} High LOAD: $LOAD"
  fi
  [ "$PS_COUNT" -gt "$LIMITE_PROC" ] && echo -e "  ${ROJO}${BOLD}WARNING:${NC} Exceso de procesos: $PS_COUNT (Límite: $LIMITE_PROC)"
  [ "$CONEXIONES" -gt "$LIMITE_CONX" ] && echo -e "  ${ROJO}${BOLD}WARNING:${NC} Exceso de conexiones: $CONEXIONES (Límite: $LIMITE_CONX)"
}

output_ansible() {
  echo "HOSTNAME: $HOSTNAME"
  echo "OS: $OS"
  echo "VERSION: $VERSION"
  echo "UPTIME: $UPTIME"
  echo "INSTALL_DATE: $FECINS"
  echo "INSTALL_AGE: $ANTIGUEDAD"
  echo "LOAD: ${LOAD:-0}"
  echo "CPU_USAGE: ${CPU_USAGE_PERC:-0}%"
  echo "IOWAIT: ${IOWAIT_PERC:-0}%"
  echo "MEM_USAGE: ${MEM_PERC:-0}%"
  echo "MEM_TOTAL_MB: ${MEMTOTAL:-0}"
  echo "MEM_FREE_MB: ${MEMFREE:-0}"
  echo "FAILED_SERVICES: ${FAILED_SERVICES_COUNT:-0}"
  echo "CONNECTIONS: ${CONEXIONES:-0}"
  echo "RX_ERRORS: ${RX_ERRS:-0}"
  echo "TX_ERRORS: ${TX_ERRS:-0}"
  echo "DISK_ALERTS: $(echo "$DISCOS_DATA" | awk -F: '$2>90{count++} END{print count+0}')"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
}

output_json() {
  cat <<EOF
{
  "hostname": "$HOSTNAME",
  "os": "$(json_escape "$OS")",
  "version": "$VERSION",
  "uptime": "$UPTIME",
  "install_date": "$FECINS",
  "install_age": "$ANTIGUEDAD",
  "cpu": {
    "model": "$(json_escape "$PROC")",
    "mhz": ${MHZ:-0},
    "cores": ${CORES:-1},
    "usage": ${CPU_USAGE_PERC:-0},
    "iowait": ${IOWAIT_PERC:-0},
    "load": ${LOAD:-0}
  },
  "memory": {
    "total_mb": ${MEMTOTAL:-0},
    "used_mb": ${MEMUSED:-0},
    "free_mb": ${MEMFREE:-0},
    "usage_pct": ${MEM_PERC:-0}
  },
  "network": {
    "interface": "$IFACE",
    "ip": "$IP",
    "rx_bytes": ${RX_BYTES:-0},
    "tx_bytes": ${TX_BYTES:-0},
    "rx_errors": ${RX_ERRS:-0},
    "tx_errors": ${TX_ERRS:-0},
    "connections": ${CONEXIONES:-0}
  },
  "health": {
    "failed_services": ${FAILED_SERVICES_COUNT:-0},
    "processes": ${PS_COUNT:-0},
    "users": ${USERS:-0}
  }
}
EOF
}

# --- EJECUCIÓN ---
collect_data
if [ "$JSON" -eq 1 ]; then output_json; elif [ "$ANSIBLE" -eq 1 ]; then output_ansible; else render_dashboard; fi
echo " "

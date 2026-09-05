#!/bin/bash
#
# stats.sh - Sistema de monitoreo ligero para servidores Linux
# Versión: 2.1
# Autor: Cristian Gimenez <cgimenez@gmail.com>
# https://github.com/kastormdz/stats.sh
#

if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  else
    echo "Error: stats.sh requiere bash >= 3.2" >&2
    exit 1
  fi
fi

export LC_NUMERIC=C

WIDTH=80
ANSIBLE=0
JSON=0
COLOR=1
VERBOSE=0
FAST=0
LIMITE_PROC=300
LIMITE_CONX=200

log_debug() { [ "$VERBOSE" -eq 1 ] && echo "[DEBUG] $*" >&2; }

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

strip_ansi() {
  local s="$1" e code
  printf -v s '%b' "$s"
  e=$'\e'
  for code in '[0m' '[1m' '[0;32m' '[0;31m' '[0;34m' '[0;37m'; do
    s=${s//"$e$code"/}
  done
  printf '%s' "$s"
}

usage() {
  echo "Uso: $0 [OPCIONES]"
  echo "Opciones:"
  echo "  -a, --ansible    Modo compatible con Ansible (output simple)"
  echo "  -j, --json       Salida en formato JSON"
  echo "  -n, --no-color   Desactivar colores"
  echo "  -w, --width N    Ajustar ancho del recuadro (40-200, default: 80)"
  echo "  -v, --verbose    Mostrar información de depuración"
  echo "  -f, --fast       Modo rápido: omite versiones y chequeo de fallidos"
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
  -f | --fast)
    FAST=1
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

get_service_version() {
  local cmd="$1"
  local bin

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

  if [ "$cmd" = "java" ] || [ "$cmd" = "Tomcat" ]; then
    if command -v tomcat >/dev/null 2>&1; then
      ver=$(tomcat version 2>/dev/null | grep "Server number" | cut -d: -f2 | xargs)
      [ -n "$ver" ] && {
        echo "$ver"
        return 0
      }
    fi
    local t_home="${TOMCAT_HOME:-}"
    if [ -n "$t_home" ] && [ -d "$t_home" ]; then
      local t_jar="${CATALINA_JAR:-$t_home/lib/catalina.jar}"
      if [ ! -f "$t_jar" ] && [ -z "${CATALINA_JAR:-}" ]; then
        t_jar=$(find "$t_home" -maxdepth 3 -name "catalina.jar" 2>/dev/null | head -n1)
      fi
      if [ -f "$t_jar" ]; then
        ver=$("${bin:-java}" -cp "$t_jar" org.apache.catalina.util.ServerInfo 2>/dev/null | grep "Server number" | cut -d: -f2 | xargs)
        [ -n "$ver" ] && {
          echo "$ver"
          return 0
        }
      fi
    fi
  fi

  [ -z "$bin" ] && return 1

  if command -v dpkg-query >/dev/null 2>&1; then
    local pkg
    pkg=$(dpkg-query -S "$bin" 2>/dev/null | awk -F: '{print $1}' | head -n1)
    if [ -n "$pkg" ]; then
      ver=$(dpkg-query -W -f='${Version}\n' "$pkg" 2>/dev/null)
    fi
  elif command -v rpm >/dev/null 2>&1; then
    ver=$(rpm -qf --qf '%{VERSION}\n' "$bin" 2>/dev/null | head -n1)
  elif command -v pacman >/dev/null 2>&1; then
    ver=$(pacman -Qo "$bin" 2>/dev/null | awk '{print $NF}')
  fi

  if [ -z "$ver" ] || [[ "$ver" == *"not owned"* ]] || [[ "$ver" == *"no package"* ]]; then
    if [ "$cmd" = "java" ]; then
      ver=$("$bin" -version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    else
      ver=$("$bin" -v 2>&1 || "$bin" --version 2>&1 || "$bin" -V 2>&1)
      ver=$(echo "$ver" | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    fi
  fi

  if [ -n "$ver" ]; then
    if [[ "$ver" =~ ^[0-9]+:(.*) ]]; then ver="${BASH_REMATCH[1]}"; fi
    printf '%s\n' "$ver"
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
  local rpm_date=""
  if command -v rpm >/dev/null 2>&1; then
    rpm_date=$(LC_ALL=C rpm -q --qf '%{INSTALLTIME:date}\n' basesystem 2>/dev/null | awk '{print $4"-"$3"-"$2}' | sed 's/Jan/01/;s/Feb/02/;s/Mar/03/;s/Apr/04/;s/May/05/;s/Jun/06/;s/Jul/07/;s/Aug/08/;s/Sep/09/;s/Oct/10/;s/Nov/11/;s/Dec/12/')
  fi
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
  HOSTNAME=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "unknown")
  OS=$(grep PRETTY /etc/os-release 2>/dev/null | cut -d= -f2 | sed 's/\"//g')
  [ -z "$OS" ] && OS=$(cat /etc/redhat-release 2>/dev/null || cat /etc/centos-release 2>/dev/null || cat /etc/system-release 2>/dev/null || echo "Unknown")
  VERSION=$(uname -sr 2>/dev/null || echo "Unknown")
  UPTIME_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
  case "$UPTIME_S" in ''|*[!0-9]*) UPTIME_S=0;; esac
  UPTIME_D=$((UPTIME_S / 86400))
  UPTIME_H=$((UPTIME_S % 86400 / 3600))
  UPTIME_M=$((UPTIME_S % 3600 / 60))
  UPTIME="${UPTIME_D}d ${UPTIME_H}h ${UPTIME_M}m"
  LAST_REBOOT=$(uptime -s 2>/dev/null | cut -d: -f1,2)
  [ -z "$LAST_REBOOT" ] && LAST_REBOOT=$(who -b 2>/dev/null | awk '{print $3, $4}')
  LAST_REBOOT=$(printf '%s' "$LAST_REBOOT" | xargs 2>/dev/null || printf '%s' "$LAST_REBOOT")
  USERS=$(LC_ALL=C uptime 2>/dev/null | grep -oE '[0-9]+ users?' | grep -oE '[0-9]+' | head -n1)
  [ -z "$USERS" ] && USERS=0
  INSTALADO=$(detect_install_date)
  FECINS=$(printf '%s' "$INSTALADO" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1)
  [ -z "$FECINS" ] && FECINS="desconocida"
  ACTUAL_DATE=$(date +%Y-%m-%d)
  if [ "$FECINS" = "desconocida" ]; then
    ANTIGUEDAD="?"
  else
    ANTIGUEDAD=$(awk -v d1="$FECINS" -v d2="$ACTUAL_DATE" 'BEGIN {
        split(d1, a, "-"); split(d2, b, "-");
        y = b[1] - a[1]; m = b[2] - a[2];
        if (b[3] < a[3]) m--;
        if (m < 0) { y--; m += 12; }
        if (y > 0) printf "%da", y;
        else printf "%dm", m;
    }')
  fi
}

collect_cpu_info() {
  local _cpu
  _cpu=$(awk '/model name[ \t]*:/ {sub(/.*: /,""); p=$0} p == "" && /^[Mm]odel[ \t]*:/ {sub(/.*: /,""); p=$0} /cpu MHz/ {sub(/.*: /,""); sub(/\..*/,""); m=$0} END {print p; print m}' /proc/cpuinfo 2>/dev/null)
  case "$_cpu" in
    *$'\n'*) PROC=${_cpu%%$'\n'*}; MHZ=${_cpu#*$'\n'}; MHZ=${MHZ%%$'\n'*};;
    *) PROC=$_cpu; MHZ="";;
  esac
  [ -z "$PROC" ] && PROC=$(uname -m 2>/dev/null || echo "unknown")
  CORES=$(nproc 2>/dev/null)
  [ -z "$CORES" ] && CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
  case "$CORES" in ''|*[!0-9]*) CORES=1;; esac
  [ "$CORES" -lt 1 ] && CORES=1
  LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
  [ -z "$LOAD" ] && LOAD=0
  local _pids=(/proc/[0-9]*)
  if [ "${#_pids[@]}" -eq 1 ] && [ ! -e "${_pids[0]}" ]; then PS_COUNT=0; else PS_COUNT=${#_pids[@]}; fi
}

collect_memory_info() {
  read -r MEMTOTAL MEMUSED MEMFREE <<<"$(free -m 2>/dev/null | grep Mem: | awk '{print $2, $3, $4}')"
  if [ -z "$MEMTOTAL" ] && [ -r /proc/meminfo ]; then
    read -r MEMTOTAL MEMFREE <<<"$(awk '/^MemTotal:/ {t=int($2/1024)} /^MemAvailable:/ {a=int($2/1024)} /^MemFree:/ {f=$2} /^Buffers:/ {b=$2} /^Cached:/ {c=$2} END {if (t != "") {if (a == "") a=int((f+b+c)/1024); print t, a}}' /proc/meminfo 2>/dev/null)"
    [ -n "$MEMTOTAL" ] && MEMUSED=$((MEMTOTAL - MEMFREE))
  fi
  case "$MEMTOTAL" in ''|*[!0-9]*) MEMTOTAL=0;; esac
  case "$MEMUSED" in ''|*[!0-9]*) MEMUSED=0;; esac
  case "$MEMFREE" in ''|*[!0-9]*) MEMFREE=0;; esac
  if [ "$MEMTOTAL" -gt 0 ] 2>/dev/null; then
    MEM_PERC=$((MEMUSED * 100 / MEMTOTAL))
  else
    MEM_PERC=0
  fi
}

collect_network_info() {
  IFACE=""; IP=""
  if command -v ip >/dev/null 2>&1; then
    read -r IFACE IP <<<"$(ip -4 addr show 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $NF, $2; exit}')"
  elif command -v ifconfig >/dev/null 2>&1; then
    read -r IFACE IP <<<"$(ifconfig 2>/dev/null | awk '/^[^ ]/ {iface=$1; sub(/:$/, "", iface)} /inet / && $0 !~ /127\.0\.0\.1/ {for (i=1; i<=NF; i++) {ip=$i; sub(/^addr:/, "", ip); if (ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print iface, ip; exit}}}')"
  fi
  if [ -n "$IFACE" ]; then
    IFACE_CLEAN=${IFACE//:/}
    read -r RX_BYTES TX_BYTES RX_ERRS TX_ERRS <<< \
      "$(awk -v iface="$IFACE_CLEAN" '$1 == iface":" {gsub(/:/," "); print $2, $10, $4, $12}' /proc/net/dev 2>/dev/null)"
    RX_HUMAN=$(awk -v b="$RX_BYTES" "BEGIN { if (b>1024*1024*1024) printf \"%.2f GB\", b/1024/1024/1024; else printf \"%.2f MB\", b/1024/1024 }")
    TX_HUMAN=$(awk -v b="$TX_BYTES" "BEGIN { if (b>1024*1024*1024) printf \"%.2f GB\", b/1024/1024/1024; else printf \"%.2f MB\", b/1024/1024 }")
    if command -v ss >/dev/null 2>&1; then
      CONEXIONES=$(ss -tun 2>/dev/null | awk 'NR>1 && $0 !~ /LISTEN/ {c++} END{print c+0}')
    elif command -v netstat >/dev/null 2>&1; then
      CONEXIONES=$(netstat -tun 2>/dev/null | awk 'NR>2 && $0 !~ /LISTEN/ {c++} END{print c+0}')
    else
      CONEXIONES=0
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
  STATS_TMPDIR=$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/stats.$$" && printf '%s' "/tmp/stats.$$"; })
  _stats_cleanup() {
    rm -rf "$STATS_TMPDIR" 2>/dev/null
    if [ "$JSON" -eq 0 ] && [ "$ANSIBLE" -eq 0 ]; then
      [ -t 1 ] && tput cnorm 2>/dev/null
    fi
  }
  trap '_stats_cleanup' EXIT INT TERM

  TOMCAT_HOME=""
  CATALINA_JAR=""
  if [ "$FAST" -eq 0 ]; then
    TOMCAT_HOME=$(ps -eo args 2>/dev/null | sed -n 's/.*Dcatalina\.\(home\|base\)=\([^ ]*\).*/\2/p' | head -n1)
  fi
  export TOMCAT_HOME CATALINA_JAR
  if [ -n "$TOMCAT_HOME" ] && [ -d "$TOMCAT_HOME" ]; then
    [ -f "$TOMCAT_HOME/lib/catalina.jar" ] && CATALINA_JAR="$TOMCAT_HOME/lib/catalina.jar"
    export CATALINA_JAR
  fi

  {
    if command -v ss >/dev/null 2>&1; then
      ss -plunt 2>/dev/null | awk '
        BEGIN { while ((getline < "/etc/services") > 0) { if (index($2, "/") > 0) { split($2, p, "/"); if (!(p[1] in svc_map)) svc_map[p[1]] = $1; } } }
        NR>1 {
            n=split($5, a, ":"); port=a[n];
            name="unknown";
            if (index($0, "\"") > 0) { tmp=$0; sub(/^[^"]*"/, "", tmp); sub(/".*$/, "", tmp); if (tmp != "") name=tmp; }
            else if (port in svc_map) name=svc_map[port];

            if (!((name "_" port) in seen)) {
                services[name] = (services[name] ? services[name] "," port : port);
                seen[name "_" port] = 1
            }
        } END { for (s in services) print s ":" services[s]; }' | sort -u >"$STATS_TMPDIR/services"
    elif command -v netstat >/dev/null 2>&1; then
      netstat -plunt 2>/dev/null | awk '
        BEGIN { while ((getline < "/etc/services") > 0) { if (index($2, "/") > 0) { split($2, p, "/"); if (!(p[1] in svc_map)) svc_map[p[1]] = $1; } } }
        NR>2 {
            n=split($4, a, ":"); port=a[n];
            name="unknown";
            if ($1 ~ /^tcp/) prog=$7; else prog=$6;
            slashidx=index(prog, "/");
            if (slashidx > 1) {
                tmp=substr(prog, slashidx + 1);
                cut=0; sp=index(tmp, " "); sl2=index(tmp, "/");
                if (sp > 0) cut=sp;
                if (sl2 > 0 && (cut == 0 || sl2 < cut)) cut=sl2;
                if (cut > 0) tmp=substr(tmp, 1, cut - 1);
                if (tmp != "" && tmp != "-") name=tmp;
            }
            if (name == "unknown" && (port in svc_map)) name=svc_map[port];

            if (!((name "_" port) in seen)) {
                services[name] = (services[name] ? services[name] "," port : port);
                seen[name "_" port] = 1
            }
        } END { for (s in services) print s ":" services[s]; }' | sort -u >"$STATS_TMPDIR/services"
    else
      : >"$STATS_TMPDIR/services"
    fi

    if [ "$FAST" -eq 1 ]; then
      grep -v '^unknown:' "$STATS_TMPDIR/services" >"$STATS_TMPDIR/services_new" 2>/dev/null || : >"$STATS_TMPDIR/services_new"
      : >"$STATS_TMPDIR/service_versions"
      mv "$STATS_TMPDIR/services_new" "$STATS_TMPDIR/services"
    else
      : >"$STATS_TMPDIR/services_new"
      : >"$STATS_TMPDIR/service_versions"
      _svc_idx=0
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        svc_name="${line%%:*}"
        svc_ports="${line#*:}"
        [ "$svc_name" = "unknown" ] && continue

        _final_name="$svc_name"
        if [ "$svc_name" = "java" ]; then
          if [ -n "$TOMCAT_HOME" ] || command -v tomcat >/dev/null 2>&1; then
            _final_name="Tomcat"
          fi
        fi
        if [ "$svc_name" = "master" ]; then
          _final_name="Postfix"
        fi
        printf '%s:%s\n' "$_final_name" "$svc_ports" >>"$STATS_TMPDIR/services_new"

        _svc_idx=$((_svc_idx + 1))
        (
          svc_ver=$(get_service_version "$svc_name")
          [ -n "$svc_ver" ] && printf '%s:%s\n' "$_final_name" "$svc_ver" >"$STATS_TMPDIR/sv.$_svc_idx"
        ) &
      done <"$STATS_TMPDIR/services"
      wait
      cat "$STATS_TMPDIR"/sv.* 2>/dev/null >>"$STATS_TMPDIR/service_versions"
      mv "$STATS_TMPDIR/services_new" "$STATS_TMPDIR/services"
    fi
  } &
  (df -P -h 2>/dev/null | awk 'NR>1 && $0 !~ /tmpfs|none|udev|shm|loop|efivarfs|overlay|nsfs/ {gsub(/%/,"",$5); print $6":"$5":"$2":"$4}' >"$STATS_TMPDIR/discos") &
  (ps -eo comm,pcpu,pmem 2>/dev/null | tail -n +2 >"$STATS_TMPDIR/psraw";
   sort -k3 -nr "$STATS_TMPDIR/psraw" 2>/dev/null | awk 'NR<=3 {printf "%s%s", sep, $1; sep=", "}' >"$STATS_TMPDIR/ram";
   sort -k2 -nr "$STATS_TMPDIR/psraw" 2>/dev/null | awk 'NR<=3 {printf "%s%s", sep, $1; sep=", "}' >"$STATS_TMPDIR/cpu_top") &

  sleep 0.3
  CPU_2=$(head -n1 /proc/stat)
  wait
  SERVICES=$(cat "$STATS_TMPDIR/services" 2>/dev/null)
  SERVICE_VERSIONS=$(sort -u "$STATS_TMPDIR/service_versions" 2>/dev/null)
  TOP_RAM_LIST=$(cat "$STATS_TMPDIR/ram" 2>/dev/null)
  TOP_CPU_LIST=$(cat "$STATS_TMPDIR/cpu_top" 2>/dev/null)
  DISCOS_DATA=$(cat "$STATS_TMPDIR/discos" 2>/dev/null)

  if [ "$FAST" -eq 1 ]; then
    FAILED_SERVICES_LIST=""
    FAILED_SERVICES_COUNT=0
  elif command -v systemctl >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      FAILED_SERVICES_LIST=$(timeout 3 systemctl list-units --failed --type=service --no-legend --no-pager 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i~/\.service/) print $i}')
    else
      FAILED_SERVICES_LIST=$(systemctl list-units --failed --type=service --no-legend --no-pager 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i~/\.service/) print $i}')
    fi
    FAILED_SERVICES_COUNT=$(printf '%s' "$FAILED_SERVICES_LIST" | awk 'NF{c++} END{print c+0}')
  elif command -v rc-status >/dev/null 2>&1; then
    FAILED_SERVICES_LIST=$(rc-status --crashed 2>/dev/null | awk '{print $1}')
    FAILED_SERVICES_COUNT=$(printf '%s' "$FAILED_SERVICES_LIST" | awk 'NF{c++} END{print c+0}')
  else
    FAILED_SERVICES_LIST=""
    FAILED_SERVICES_COUNT=0
  fi

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

draw_line() {
  local text="$1"
  local target_visible=$((WIDTH - 4))
  local clean
  clean=$(strip_ansi "$text")

  local count_str="${clean//█/X}"
  count_str="${count_str//░/X}"
  count_str="${count_str//─/X}"
  count_str="${count_str//│/X}"
  local len=${#count_str}

  local padding=$((target_visible - len))
  if [ "$padding" -lt 0 ]; then
    echo -e "│ $text │"
  else
    local spacer
    printf -v spacer '%*s' "$padding" ''
    echo -e "│ $text$spacer │"
  fi
}

draw_bar() {
  local percent=${1:-0}
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

get_distro_ver() {
  [ -n "${DISTRO_NAME:-}" ] && return 0
  DISTRO_NAME=$(grep '^NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  [ -z "$DISTRO_NAME" ] && DISTRO_NAME=$(awk '{print $1}' /etc/redhat-release 2>/dev/null || echo "Unknown")
  DISTRO_VER=$(grep '^VERSION=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | awk '{print $1}')
  [ -z "$DISTRO_VER" ] && DISTRO_VER=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  [ -z "$DISTRO_VER" ] && DISTRO_VER=$(grep '^BUILD_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  [ -z "$DISTRO_VER" ] && DISTRO_VER=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release 2>/dev/null | head -n1 || echo "Rolling")
  [ -z "$DISTRO_VER" ] && DISTRO_VER="Rolling"
}

pad_label() {  local text="$1"
  local width="$2"
  local clean
  clean=$(strip_ansi "$text")

  local count_str="${clean//█/X}"
  count_str="${count_str//░/X}"
  local len=${#count_str}

  local pad=$((width - len))
  [ "$pad" -lt 0 ] && pad=0
  local spacer
  printf -v spacer '%*s' "$pad" ''
  echo -n "$text$spacer"
}

render_dashboard() {
  [ -t 1 ] && tput civis 2>/dev/null || true
  local H_LINE
  printf -v H_LINE '%*s' "$((WIDTH - 2))" ''
  H_LINE=${H_LINE// /─}
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
  local svc_cont_pad
  printf -v svc_cont_pad '%*s' "$((svc_indent + svc_name_col))" ''
  while read -r s; do
    [ -z "$s" ] && continue
    IFS=: read -r name ports <<<"$s"
    local name_vis_len=${#name}
    local padding_count=$((svc_name_col - name_vis_len))
    [ "$padding_count" -lt 0 ] && padding_count=0
    local name_colored="${VERDE}$name${NC}"
    local padding_spaces
    printf -v padding_spaces '%*s' "$padding_count" ''
    local prefix="  $name_colored$padding_spaces"
    local prefix_vis=$((svc_indent + svc_name_col))

    local current_line="$prefix"
    local current_vis=$prefix_vis
    IFS=',' read -ra ADDR <<<"$ports"
    for port in "${ADDR[@]}"; do
      local port_trimmed="${port// /}"
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
  get_distro_ver
  local d_name="$DISTRO_NAME"
  local d_ver="$DISTRO_VER"

  local ver_output="$d_name:$d_ver"
  if [ -n "$SERVICE_VERSIONS" ]; then
    while read -r sv; do
      [ -n "$sv" ] && ver_output+=",$sv"
    done <<<"$SERVICE_VERSIONS"
  fi

  local current_ver_line="  "
  local current_ver_vis=2
  IFS=',' read -ra V_ADDR <<<"$ver_output"
  for v_pair in "${V_ADDR[@]}"; do
    [ -z "$v_pair" ] && continue
    local v_name="${v_pair%%:*}"
    local v_val="${v_pair#*:}"

    local v_str="${VERDE}$v_name${NC}:${BLANCO}$v_val${NC}"
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
  echo "DISK_ALERTS: $(printf '%s' "$DISCOS_DATA" | awk -F: '$2>90{count++} END{print count+0}')"
}

json_num() {
  local v="${1:-0}"
  if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf '%s' "$v"; else printf '0'; fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
}

output_json() {
  get_distro_ver
  local _mhz _cores _usage _iowait _load
  _mhz=$(json_num "$MHZ"); _cores=$(json_num "$CORES")
  _usage=$(json_num "$CPU_USAGE_PERC"); _iowait=$(json_num "$IOWAIT_PERC"); _load=$(json_num "$LOAD")
  local _mt _mu _mf _mp
  _mt=$(json_num "$MEMTOTAL"); _mu=$(json_num "$MEMUSED"); _mf=$(json_num "$MEMFREE"); _mp=$(json_num "$MEM_PERC")
  local _rxb _txb _rxe _txe _con _fail _procs _users
  _rxb=$(json_num "$RX_BYTES"); _txb=$(json_num "$TX_BYTES")
  _rxe=$(json_num "$RX_ERRS"); _txe=$(json_num "$TX_ERRS"); _con=$(json_num "$CONEXIONES")
  _fail=$(json_num "$FAILED_SERVICES_COUNT"); _procs=$(json_num "$PS_COUNT"); _users=$(json_num "$USERS")

  local _disks_json=""
  while IFS=: read -r _m _p _t _f; do
    [ -z "$_m" ] && continue
    [ -n "$_disks_json" ] && _disks_json+=", "
    _disks_json+="{\"mount\": \"$(json_escape "$_m")\", \"use_pct\": $(json_num "$_p"), \"total\": \"$(json_escape "$_t")\", \"free\": \"$(json_escape "$_f")\"}"
  done <<<"$DISCOS_DATA"

  local _svc_json="" _ver_json=""
  while IFS=: read -r _n _pt; do
    [ -z "$_n" ] && continue
    [ -n "$_svc_json" ] && _svc_json+=", "
    _svc_json+="\"$(json_escape "$_n")\": \"$(json_escape "$_pt")\""
  done <<<"$SERVICES"
  if [ -n "$SERVICE_VERSIONS" ]; then
    while IFS=: read -r _n _v; do
      [ -z "$_n" ] && continue
      [ -n "$_ver_json" ] && _ver_json+=", "
      _ver_json+="\"$(json_escape "$_n")\": \"$(json_escape "$_v")\""
    done <<<"$SERVICE_VERSIONS"
  fi
  if [ -n "$_ver_json" ]; then
    _ver_json="\"$(json_escape "$DISTRO_NAME")\": \"$(json_escape "$DISTRO_VER")\", $_ver_json"
  else
    _ver_json="\"$(json_escape "$DISTRO_NAME")\": \"$(json_escape "$DISTRO_VER")\""
  fi

  cat <<EOF
{
  "hostname": "$(json_escape "$HOSTNAME")",
  "os": "$(json_escape "$OS")",
  "version": "$(json_escape "$VERSION")",
  "uptime": "$(json_escape "$UPTIME")",
  "install_date": "$(json_escape "$FECINS")",
  "install_age": "$(json_escape "$ANTIGUEDAD")",
  "distro": {"name": "$(json_escape "$DISTRO_NAME")", "version": "$(json_escape "$DISTRO_VER")"},
  "cpu": {
    "model": "$(json_escape "$PROC")",
    "mhz": $_mhz,
    "cores": $_cores,
    "usage": $_usage,
    "iowait": $_iowait,
    "load": $_load
  },
  "memory": {
    "total_mb": $_mt,
    "used_mb": $_mu,
    "free_mb": $_mf,
    "usage_pct": $_mp
  },
  "network": {
    "interface": "$(json_escape "$IFACE")",
    "ip": "$(json_escape "$IP")",
    "rx_bytes": $_rxb,
    "tx_bytes": $_txb,
    "rx_errors": $_rxe,
    "tx_errors": $_txe,
    "connections": $_con
  },
  "disks": [$_disks_json],
  "services": {$_svc_json},
  "service_versions": {$_ver_json},
  "health": {
    "failed_services": $_fail,
    "processes": $_procs,
    "users": $_users
  }
}
EOF
}

collect_data
if [ "$JSON" -eq 1 ]; then output_json; elif [ "$ANSIBLE" -eq 1 ]; then output_ansible; else render_dashboard; echo " "; fi

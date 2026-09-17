#!/bin/bash
# test/compat.sh - matriz de compatibilidad de stats.sh
#
# Verifica que stats.sh se comporte igual en el host actual y en distros viejas:
#   * cada modo sale con el exit code esperado (incluidas las opciones invalidas)
#   * el JSON parsea y trae las claves de memoria nuevas (available_mb)
#   * el recuadro queda alineado al caracter y la salida es UTF-8 valida,
#     incluso con locale C, donde bash corta por BYTES (bug de caracteres partidos)
#   * los fallbacks funcionan sin binarios: sin ip, sin ifconfig, sin ss
#
# Uso:
#   test/compat.sh                 host + contenedores
#   test/compat.sh --no-docker     solo el host (rapido, sin red)
#   test/compat.sh --help          esta ayuda
#
# Variables: COMPAT_IMAGES, COMPAT_LOCALES, COMPAT_WIDTHS
# Requiere: bash >= 3.2 y python3 (validador). Docker solo para la parte de distros viejas.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SELF="$ROOT/stats.sh"
CHECK="$ROOT/test/check.py"
IMAGES=${COMPAT_IMAGES:-"centos:5.11 centos:6.10 debian:bullseye-slim"}
LOCALES=${COMPAT_LOCALES:-"C C.UTF-8 en_US.UTF-8 es_AR.UTF-8"}
WIDTHS=${COMPAT_WIDTHS:-"40 80 200"}
USE_DOCKER=1

PASS=0
FAIL=0
OUT=$(mktemp -d 2>/dev/null) || { echo "no puedo crear el directorio temporal" >&2; exit 1; }
KEEP=${COMPAT_KEEP:-0}
trap '[ "$KEEP" -eq 1 ] || rm -rf "$OUT" 2>/dev/null || true' EXIT

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
[ "${1:-}" = "--no-docker" ] && USE_DOCKER=0

# Cualquier asercion sobre la salida RENDERIZADA debe sacar los codigos ANSI primero:
# el script emite color real ([0;34m), asi que un patron como '@ 192\.' no matchea
# aunque en pantalla se lea perfecto. Pitfall real: el test fallaba y el script estaba bien.
strip_ansi() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }

head1() { printf '\n=== %s ===\n' "$*"; }
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FALLA %s\n' "$*"; }

# --- 1. modos, exit codes y JSON en el host -------------------------------------
test_modes() {
  head1 "modos y exit codes (host)"
  local rc

  "$SELF" >"$OUT/def.txt" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "default -> exit 0" || bad "default -> exit $rc"

  "$SELF" -j >"$OUT/json.txt" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "-j -> exit 0" || bad "-j -> exit $rc"
  python3 "$CHECK" --json "$OUT/json.txt" >"$OUT/j.log" 2>&1 \
    && ok "$(cat "$OUT/j.log")" || bad "JSON: $(cat "$OUT/j.log")"

  "$SELF" -a >"$OUT/ans.txt" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "-a -> exit 0" || bad "-a -> exit $rc"
  grep -q '^MEM_AVAILABLE_MB: [0-9]' "$OUT/ans.txt" && ok "ansible expone MEM_AVAILABLE_MB" \
    || bad "ansible sin MEM_AVAILABLE_MB"

  "$SELF" --fast >"$OUT/fast.txt" 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "--fast -> exit 0" || bad "--fast -> exit $rc"

  "$SELF" --pepito >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "opcion invalida -> exit 1" || bad "opcion invalida -> exit $rc (esperado 1)"

  "$SELF" -w 39 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "-w fuera de rango -> exit 1" || bad "-w 39 -> exit $rc (esperado 1)"

  "$SELF" -h >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "-h -> exit 0" || bad "-h -> exit $rc"

  "$SELF" 1 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "legacy '1' -> exit 0" || bad "legacy '1' -> exit $rc"
}

# --- 2. matriz locale x ancho: UTF-8 y alineacion -------------------------------
test_widths() {
  head1 "locale x ancho (UTF-8 y recuadro)"
  local L W log
  for L in $LOCALES; do
    for W in $WIDTHS; do
      LANG=$L "$SELF" -w "$W" >"$OUT/w.txt" 2>/dev/null
      log=$(python3 "$CHECK" "$OUT/w.txt" "$W" 2>&1)
      case "$log" in
      OK*) ok "LANG=$L -w $W" ;;
      *) bad "LANG=$L -w $W -> $log" ;;
      esac
    done
  done
}

# --- 3. fallbacks sin binarios: ip / ifconfig / ss ------------------------------
test_fallbacks() {
  head1 "fallbacks sin binarios de red (ip, ifconfig, ss)"
  local shim d f b
  shim=$(mktemp -d) || return
  for d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b=${f##*/}
      case "$b" in ip | ifconfig | ss) continue ;; esac
      [ -e "$shim/$b" ] || ln -s "$f" "$shim/$b" 2>/dev/null
    done
  done

  local sin_ip sin_if sin_ss linea_red
  PATH="$shim" bash -c 'command -v ip >/dev/null && echo SI || echo NO' >"$OUT/chk_ip" 2>&1
  PATH="$shim" bash -c 'command -v ifconfig >/dev/null && echo SI || echo NO' >"$OUT/chk_if" 2>&1
  PATH="$shim" bash -c 'command -v ss >/dev/null && echo SI || echo NO' >"$OUT/chk_ss" 2>&1
  sin_ip=$(cat "$OUT/chk_ip"); sin_if=$(cat "$OUT/chk_if"); sin_ss=$(cat "$OUT/chk_ss")

  PATH="$shim" "$SELF" --fast >"$OUT/fb.txt" 2>"$OUT/fb.err"
  linea_red=$(grep -E '\[(RED|NETWORK)\]' -A2 "$OUT/fb.txt" | grep -E 'Placa|NIC' | strip_ansi | head -1)

  if [ -n "$linea_red" ] && printf '%s' "$linea_red" | grep -qE '@ [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    ok "sin ip/ifconfig/ss resuelve NIC + IP por /proc"
  else
    bad "fallback de red incompleto -> '$linea_red'"
    echo "        ocultos: ip=$sin_ip ifconfig=$sin_if ss=$sin_ss"
    echo "        stderr: $(head -c 200 "$OUT/fb.err")"
  fi
  python3 "$CHECK" "$OUT/fb.txt" 80 >/dev/null 2>&1 && ok "recuadro alineado en modo fallback" \
    || bad "recuadro desalineado en modo fallback"
  rm -rf "$shim"
}

# --- 4. distros viejas en contenedores ------------------------------------------
validate_container() { # $1 = tag
  local tag=$1 log
  for pair in "def 80" "w40 40" "es 80" "noip 80"; do
    set -- $pair
    log=$(python3 "$CHECK" "$OUT/${tag}_$1.txt" "$2" 2>&1)
    case "$log" in
    OK*) ok "$tag $1" ;;
    *) bad "$tag $1 -> $log" ;;
    esac
  done
  log=$(python3 "$CHECK" --json "$OUT/${tag}_json.txt" 2>&1)
  case "$log" in
  OK*) ok "$tag json" ;;
  *) bad "$tag json -> $log" ;;
  esac
}

test_docker() {
  command -v docker >/dev/null 2>&1 || { head1 "docker"; echo "  (docker no disponible: omitido)"; return; }
  local img tag
  for img in $IMAGES; do
    tag=$(printf '%s' "$img" | tr ':/' '__')
    head1 "docker $img"
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      echo "  bajando $img ..."
      docker pull -q "$img" >/dev/null 2>&1 || { bad "no se pudo bajar $img"; continue; }
    fi
    docker run --rm -v "$ROOT:/repo:ro" -v "$OUT:/out" -v "$ROOT/test:/t:ro" "$img" \
      bash /t/inner.sh "$tag" 2>&1 | grep -E 'exit=|bash |stderr' | sed 's/^/  /'
    validate_container "$tag"
  done
}

test_modes
test_widths
test_fallbacks
[ "$USE_DOCKER" -eq 1 ] && test_docker

printf '\n=== resumen: %d ok, %d fallas ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

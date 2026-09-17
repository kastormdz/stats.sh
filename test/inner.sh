#!/bin/bash
# Corre DENTRO del contenedor. Deja las salidas en /out (montado por el host) para que
# las valide el host: los contenedores viejos no tienen python3 para correr check.py.
TAG="${1:-container}"
O=/out

echo "  bash ${BASH_VERSION} | awk: $(awk --version 2>&1 | head -1)"

bash /repo/stats.sh >"$O/${TAG}_def.txt" 2>"$O/${TAG}.err"
echo "  default        exit=$?"
bash /repo/stats.sh -j >"$O/${TAG}_json.txt" 2>>"$O/${TAG}.err"
echo "  -j             exit=$?"
bash /repo/stats.sh -a >"$O/${TAG}_ans.txt" 2>>"$O/${TAG}.err"
echo "  -a             exit=$?"
bash /repo/stats.sh --fast -w 40 >"$O/${TAG}_w40.txt" 2>>"$O/${TAG}.err"
echo "  --fast -w 40   exit=$?"
LANG=es bash /repo/stats.sh >"$O/${TAG}_es.txt" 2>>"$O/${TAG}.err"
echo "  LANG=es        exit=$?"

bash /repo/stats.sh --pepito >/dev/null 2>&1
echo "  --pepito       exit=$? (esperado 1)"
bash /repo/stats.sh -w 39 >/dev/null 2>&1
echo "  -w 39          exit=$? (esperado 1)"
bash /repo/stats.sh -h >/dev/null 2>&1
echo "  -h             exit=$? (esperado 0)"
bash /repo/stats.sh 1 >/dev/null 2>&1
echo "  legacy '1'     exit=$? (esperado 0)"

# Fallback sin herramientas de red: se mueven los binarios dentro del contenedor
# (es efimero, --rm) para forzar las ramas /proc y netstat.
for b in /sbin/ip /usr/sbin/ip /bin/ip /sbin/ifconfig /usr/sbin/ifconfig /bin/ifconfig; do
  [ -e "$b" ] && mv "$b" "$b.off" 2>/dev/null
done
bash /repo/stats.sh --fast >"$O/${TAG}_noip.txt" 2>>"$O/${TAG}.err"
echo "  sin ip/ifcfg   exit=$?"

[ -s "$O/${TAG}.err" ] && echo "  stderr: $(head -c 200 "$O/${TAG}.err")"
exit 0

#!/bin/bash
# 
# https://github.com/kastormdz/stats.sh
#
PROC=$( cat /proc/cpuinfo | grep model| tail -n 1| cut -d : -f 2)
CORES=$(nproc)
UPTIME=$(cat /proc/loadavg | awk '{print $1}')
FECINS=$(ls --time-style=+%Y-%m-%d -lct /etc | tail -1 | awk '{print $6}')
ANIO=$(echo $FECINS | cut -f1 -d -)
ACTUAL=$(date +%Y)
DIFF=$(expr $ACTUAL - $ANIO)
PS=$(ps afx | wc -l)
MEMTOTAL=$(free -m|grep Mem: | awk '{print $2}')
MEMUSED=$(free -m|grep Mem: | awk '{print $3}')
MEMFREE=$(free -m|grep Mem: | awk '{print $4}')
echo "+-----------------------------------------------------------------------------------------------------------------------------+"
echo "| Hostname: $(hostname)  |          "
echo "+-----------------------------------------------------------------------------------------------------------------------------+"
echo "| CPU: $PROC  | Cores: $CORES | Load: $UPTIME  "
echo "| Instalacion Server: $FECINS  | $DIFF año(s) de Antiguedad                                             "
echo "| Uptime: $(uptime)  "
echo "| Cantidad de Procesos: $PS "
echo "| MEMORIA Total: $MEMTOTAL Mb   Usada: $MEMUSED Mb   Libre: $MEMFREE Mb "
if [ -f /proc/drbd ] ; then
echo -n "|  Estado DRBD: "
echo "$(cat /proc/drbd | grep Primary | awk {'print $3  $4'} | sed 's/st://' | sed 's/ld:/  Estado: /')"
else
    echo "| DISCOS:  "
fi
DF=$(df -Th | grep -v tmpfs | grep -v none| grep -v udev | grep -v shm | grep -v loop)
for a in "${DF}" ; do
	echo "| $a"
done
discos=$(df -h | grep -v tmpfs | grep -v none| grep -v udev | grep -v shm | grep -v loop  | awk '{print $5}' | tr -d '%' | grep -v U)
for a in $discos ; do
    if [ $a -gt 90 ] ; then
       echo "|  *******************************************************************"
       echo "|  ******************* W A R N I N G  $a % USADO *******************"
       echo "|  *******************************************************************"
    fi
done
echo "+-----------------------------------------------------------------------------------------------------------------------------+"
echo " "
echo " "

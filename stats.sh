#!/bin/bash
PROC=$( cat /proc/cpuinfo | grep model| tail -n 1| cut -d : -f 2)
CORES=$(nproc)
UPTIME=$(uptime|cut -d : -f 5| cut -d " " -f 2 | rev | cut -c 2- | rev)
FECINS=$(ls --time-style=+%Y-%m-%d -lct /etc | tail -1 | awk '{print $6}')
ANIO=$(echo $FECINS | cut -f1 -d -)
ACTUAL=$(date +%Y)
DIFF=$(expr $ACTUAL - $ANIO)
PS=$(ps afx | wc -l)
echo "+------------------------------------------------------------------------------------------------------------------------------"
echo "| HOSTNAME: $(hostname)  |          "
echo "+------------------------------------------------------------------------------------------------------------------------------"
echo "| PROC: $PROC  | CORES: $CORES | CARGA: $UPTIME  "
echo "+------------------------------------------------------------------------------------------------------------------------------"
echo "| INSTALACION SERVER: $FECINS  | $DIFF año(s) de Antiguedad                                             "
echo "+------------------------------------------------------------------------------------------------------------------------------"
echo "| $(uptime)  "
echo "|  Procesos: $PS "
echo "-------------------------------------------------------------------------------------------------------------------------------"
if [ -f /proc/drbd ] ; then
echo -n "|  Estado DRBD: "
echo "$(cat /proc/drbd | grep Primary | awk {'print $3  $4'} | sed 's/st://' | sed 's/ld:/  Estado: /')"
else
    echo "| DISCOS:  "
fi
echo "-------------------------------------------------------------------------------------------------------------------------------"
df -Th | grep -v tmpfs | grep -v none| grep -v udev | grep -v shm | grep -v loop
discos=$(df -h | grep -v tmpfs | grep -v none| grep -v udev | grep -v shm | grep -v loop  | awk '{print $5}' | tr -d '%' | grep -v U)

for a in $discos ; do
    if [ $a -gt 90 ] ; then
       echo "*******************************************************************"
       echo "******************* W A R N I N G  $a % USADO *******************"
       echo "*******************************************************************"
    fi
done


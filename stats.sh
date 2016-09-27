#!/bin/bash
PROC=$( cat /proc/cpuinfo | grep model| tail -n 1| cut -d : -f 2)
UPTIME=$(uptime|cut -d : -f 5| cut -d " " -f 2 | rev | cut -c 2- | rev)
FECINS=$(ls --time-style=+%Y-%m-%d -lct /etc | tail -1 | awk '{print $6}')
ANIO=$(echo $FECINS | cut -f1 -d -)
ACTUAL=$(date +%Y)
DIFF=$(expr $ACTUAL - $ANIO)
echo "+------------------------------------------------------------------------------------------------------------------------------"
echo "| HOSTNAME: $(hostname)  |          "
echo "+------------------------------------------------------------------------------------------------------------------------------"
echo "| PROCESADOR: $PROC  |  CARGA: $UPTIME  "
echo "+------------------------------------------------------------------------------------------------------------------------------"
echo "| INSTALACION SERVER: $FECINS  | $DIFF año(s) de Antiguedad                                             "
echo "+------------------------------------------------------------------------------------------------------------------------------"
echo "$( top -b -n1 | head -5)"
echo "-------------------------------------------------------------------------------------------------------------------------------"
if [ -f /proc/drbd ] ; then
echo -n "|  Estado DRBD: "
echo "$(cat /proc/drbd | grep Primary | awk {'print $3  $4'} | sed 's/st://' | sed 's/ld:/  Estado: /')"
else
    echo "| DISCOS:  "
fi
echo "-------------------------------------------------------------------------------------------------------------------------------"
df -h | grep -v tmpfs | grep -v none| grep -v udev | grep -v shm
discos=$(df -h | grep -v tmpfs | grep -v none| grep -v udev| grep -v shm | awk '{print $5}' | tr -d '%' | grep -v U)

for a in $discos ; do
    if [ $a -gt 90 ] ; then
       echo "*******************************************************************"
       echo "******************* W A R N I N G  $a % USADO *******************"
       echo "*******************************************************************"
    fi
done


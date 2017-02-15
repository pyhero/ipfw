#!/bin/bash
#
# Author: Panda
# Update: 20160620

##. iptables for domain name.
##. resolv doname name to ip address & make iptables.

DIR=$(cd `dirname $0`;echo $PWD)

##. get domain name from file.
DOMAIN_NAME_FILE=$DIR/domain.list
IP_FILE=$DIR/ip.list

##. define nameservers
NAME_SERVERS="10.0.250.46 10.0.250.40"

##. global define.
WORK_DIR=/tmp/ipfw && mkdir -p $WORK_DIR
TODAY=$(date "+%Y%m%d")
Time=$(date "+%F %T")

RESAULT_FILE=$WORK_DIR/ipfwDomainWhiteList && rm -rf $RESAULT_FILE && touch $RESAULT_FILE
RESAULT_FILE_SORT=${RESAULT_FILE}.sort && touch $RESAULT_FILE_SORT
RESAULT_FILE_LAST=${RESAULT_FILE}.last && touch $RESAULT_FILE_LAST
UNDO_IPs=$WORK_DIR/undo.log && rm -rf $UNDO_IPs
LOG_FILE=$WORK_DIR/ipfw.${TODAY}.log && rm -rf $WORK_DIR/ipfw.$(date -d "7 days ago" "+%Y%m%d").log

# Random sleep.For Double run the same time.
RANDOM_FILE=$WORK_DIR/random.${TODAY} && rm -rf $WORK_DIR/random.$(date -d "7 days ago" "+%Y%m%d")
nums=(1 2 3 4 5 6 7 8 9) && num=${nums[$RANDOM % ${#nums[*]}]}
echo "Random sleep $num seconds..."
echo "[$Time] random sleep $num seconds..." >> $RANDOM_FILE
sleep $num

##. ip calc
if ! which ipcalc &> /dev/null;then
	yum -y -q install sipcalc
fi
ipcalc=$(which ipcalc)
chkIpInNet () {
	## All Private Net.
	APN="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
	if echo $ip | grep -q '^10\.' || echo $ip | grep -q '^172\.' || echo $ip | grep -q '^192\.168\.';then
		for net in $APN;do
			if [ $(ipcalc -n $ip/${net#*/}) == $(ipcalc -n $net) ];then
				continue_key=1
				echo "$DOMAIN_NAME IN A $ip: is private, no adding to iptables." >> $UNDO_IPs
				break
			fi
		done
	else
		continue_key=0
	fi
	if [ $continue_key == 1 ];then
		continue
	fi
}

##. check if running.
LOCK=$WORK_DIR/ipfw.lock
if [ ! -f $LOCK ];then
	touch $LOCK
else
	echo -e "This may already running.(To force run this,Then \e[33mrm -rf $LOCK\e[0m)"
	echo "[$Time] $LOCK already exist.Not run." >> $LOG_FILE
	exit 2
fi

##. check file
if [ ! -s $DOMAIN_NAME_FILE ];then
	echo -e "\e[32mDomain_list\e[0m:\e[31m$DOMAIN_NAME_FILE \e[0m not exist or have no records."
	echo -e "Make sure The \e[32mDomain_list \e[0mfile in \e[36mthe same directory as \e[32m$0\e[0m."
	rm -rf $LOCK
	exit 2
fi

##. check service
#. define nameserver. Need nc command to check nameser is ok
if ! which nc > /dev/null;then
	yum -y -q install nc
	[ $? -ne 0 ] && echo "install nc first.(yum -y install nc)" && rm -rf $LOCK && exit 2
fi
echo -n "check nameserver ..."
for N in $NAME_SERVERS;do
	if ! nc -uz $N 53 > /dev/null;then
		cat >> $LOG_FILE << EOF
[$Time] Connect to UDP $N:53 failed(check dns failed).
EOF
		NAME_SERVER=""
		continue
	else
		NAME_SERVER=$N
		break
	fi
done
[ -z $NAME_SERVER ] && echo -e " \e[31mfailed\e[0m." && cat $LOG_FILE && rm -rf $LOCK && exit 2
echo -e " \e[32mok\e[0m."

##. resolve domain name to ip address.
echo -n "Resolving domain name to ip address(This may take serial times) ..."
for DOMAIN_NAME in $(awk '{print $1}' $DOMAIN_NAME_FILE);do
	IPs=$(/usr/bin/dig @$NAME_SERVER $DOMAIN_NAME +short | sed '/[a-Z]/d') 
	for ip in $IPs;do
		chkIpInNet
		echo $ip >> $RESAULT_FILE
	done
done
#. add ip white list to resault
if [ -f $IP_FILE ];then
	cat $IP_FILE | awk '{print $1}' >> $RESAULT_FILE
else
	echo "ip white list:$IP_FILE not exist."
fi
#. sort ip address file.
cat $RESAULT_FILE | sed '/^[a-Z]/d' | sort -n | uniq > $RESAULT_FILE_SORT
echo -e " \e[32mok\e[0m."

##. iptables
echo -n "Updating iptables..."
if /usr/bin/diff -q $RESAULT_FILE_SORT $RESAULT_FILE_LAST > /dev/null;then
	echo -e " \e[32mAll ip \e[33mthe same as last\e[0m.\e[36mDid Nothing for iptables\e[0m."
	rm -rf $LOCK
	exit 0
else
	cp $RESAULT_FILE_SORT $RESAULT_FILE_LAST
fi

CHAIN_NAMES="domain_accept_A domain_accept_B"
if /sbin/iptables -t filter -nvL FORWARD | grep -qw "domain_accept_A";then
	CHAIN_NAME_ONLINE="domain_accept_A"
	CHAIN_NAME="domain_accept_B"
else
	CHAIN_NAME_ONLINE="domain_accept_B"
	CHAIN_NAME="domain_accept_A"
fi

RULE_FILE=$WORK_DIR/iptables.rule.${TODAY} && rm -rf $WORK_DIR/iptables.rule.$(date -d "7 days ago" "+%Y%m%d")
echo $Time >> $RULE_FILE
if ! /sbin/iptables -t filter -nvL "$CHAIN_NAME" &> /dev/null;then
	/sbin/iptables -t filter -N $CHAIN_NAME
	/sbin/iptables -t filter -F $CHAIN_NAME
	cat > $RULE_FILE << EOF
/sbin/iptables -t filter -N $CHAIN_NAME &> /dev/null
/sbin/iptables -t filter -F $CHAIN_NAME
EOF
fi

if ! /sbin/iptables -t filter -nvL $CHAIN_NAME | grep -q 'RELATED,ESTABLISHED';then
	/sbin/iptables -t filter -A $CHAIN_NAME -m state --state ESTABLISHED,RELATED -j ACCEPT
	cat > $RULE_FILE << EOF
/sbin/iptables -t filter -A $CHAIN_NAME -m state --state ESTABLISHED,RELATED -j ACCEPT
EOF
fi

for IP in $(cat $RESAULT_FILE_SORT | awk '{print $1}');do
	/sbin/iptables -t filter -A $CHAIN_NAME -s 10.0.0.0/8 -d $IP -j ACCEPT
	cat >> $RULE_FILE << EOF
/sbin/iptables -t filter -A $CHAIN_NAME -s 10.0.0.0/8 -d $IP -j ACCEPT
EOF
done
/sbin/iptables -t filter -A $CHAIN_NAME -j REJECT --reject-with icmp-host-prohibited
/sbin/iptables -t filter -A FORWARD -j $CHAIN_NAME
cat >> $RULE_FILE << EOF
/sbin/iptables -t filter -A $CHAIN_NAME -j REJECT --reject-with icmp-host-prohibited
/sbin/iptables -t filter -A FORWARD -j $CHAIN_NAME
EOF
if /sbin/iptables -t filter -nvL FORWARD | grep -qw "$CHAIN_NAME_ONLINE";then
	/sbin/iptables -t filter -D FORWARD -j $CHAIN_NAME_ONLINE
	/sbin/iptables -t filter -F $CHAIN_NAME_ONLINE
	cat >> $RULE_FILE << EOF
/sbin/iptables -t filter -D FORWARD -j $CHAIN_NAME_ONLINE &> /dev/null
/sbin/iptables -t filter -F $CHAIN_NAME_ONLINE &> /dev/null
EOF
fi
echo -e " \e[32mok\e[0m."
/sbin/service iptables save

rm -rf $LOCK

##. loglog
LOG=$WORK_DIR/ipfw.log
LOG_LIMIT=168  # lines,no hour no line,store one week.
echo "[$Time] Change To $CHAIN_NAME" >> $LOG
if [ $(wc -l $LOG | awk '{print $1}') -gt $LOG_LIMIT ];then
	sed -i '1d' $LOG
fi

echo -e "\nrun \e[32miptables -nvL\e[0m to check if iptables is ok."
[ -s $RULE_FILE ] && echo -e "\n\e[32m$RULE_FILE\e[0m: iptables rules."
[ -s $LOG_FILE ] && echo -e "\e[31m$LOG_FILE\e[0m: Error reports."

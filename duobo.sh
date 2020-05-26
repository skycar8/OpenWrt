#!/bin/sh
#modified by muziling v0.3
#并发多拨脚本
#modified by carl v0.3.1 (修正一处bug，改善友好提示信息)

#number是重拔次数，本脚本启动后一共尝试的次数
#n是几拔，同时发出几拨，理论上设置越大成功概率越大！
#ok是拔上几次后退出拔号, 要实现的预期目标
#wait time 每次单线多拨失败后，重试的等待时间

number=15
n=7
ok=2
wait=8
# avoid same with feixiang's N-WAN naming and must start with "wan"
prefix=wan
vthprefix=vth

j=$(ifconfig | grep pppoe-wan | wc -l)
if [ $j -ge $ok ] ;
then
    echo 已经是[$j]拔了，退出拔号程序。
    exit 0
fi

if [ -f /etc/config/nwannumset ] ;
then
    uci set nwannumset.@macvlan_numset[0].macvlan_num=1
    uci commit nwannumset
fi

for i in $( seq 1 $(($n-1)))
do
    ifname=$prefix$i
    ifvth=$vthprefix$i
    #ifwan=$(uci get network.wan.ifname)
    pppoe_name=$(uci get network.wan.username)
    pppoe_pw=$(uci get network.wan.password)

    if [ $(ip link | grep " ${ifvth}@eth0.2:" | wc -l) == "0" ] ;
    then
        macfac=$(ifconfig | grep eth0.2 | tr -s " " | cut -d " " -f5 | cut -b 1-8)
        mac="$macfac:"$(md5sum /proc/sys/kernel/random/uuid | sed 's/\(..\)/&:/g' | cut -b 1-8 | tr [a-f] [A-F])
        ip link add link eth0.2 $ifvth type macvlan
        ifconfig $ifvth hw ether $mac
        echo 更换MAC完毕$ifvth.
    fi

    # add /etc/config/network
    uci delete network.$ifname
    uci set network.$ifname=interface
    uci set network.$ifname.ifname=$ifvth
    #uci set network.$ifname._orig_ifname=eth0.2
    #uci set network.$ifname._orig_bridge=false
    uci set network.$ifname.proto=pppoe
    uci set network.$ifname.username=$pppoe_name
    uci set network.$ifname.password=$pppoe_pw
    uci set network.$ifname.auto=0
    uci set network.$ifname.defaultroute=0
    uci set network.$ifname.peerdns=1
    uci set network.$ifname.pppd_options="plugin rp-pppoe.so syncppp $n"

    # add /etc/config/dhcp
    uci delete dhcp.$ifvth
    uci set dhcp.$ifvth=dhcp
    uci set dhcp.$ifvth.interface=$ifname
    uci set dhcp.$ifvth.ignore=1

    if [ -f /etc/config/nwan ] ;
    then
        uci delete nwan.$ifname
        uci set nwan.$ifname=interface
        uci set nwan.$ifname.name=unicom
        uci set nwan.$ifname.route=balance
        uci set nwan.$ifname.weight=1
        uci set nwan.$ifname.uptime=0day,0hour,0min
        uci commit nwan
    fi
done

uci set network.wan.defaultroute=0
uci set network.wan.peerdns=1
uci set network.wan.pppd_options="plugin rp-pppoe.so syncppp $n"
uci commit network
uci commit dhcp

fw_wan_list=$(uci show network |grep =interface |grep -v lan|grep -v loopback |cut -d"." -f2 | awk -F "=" '{printf $1" "}')
uci set firewall.@zone[1].network="$fw_wan_list"
uci commit firewall
/etc/init.d/firewall restart

for q in $( seq 1 $number )
do
    echo
    echo ___________________________________________________
    echo 开始第$q次拔号...........
    killall -q -SIG pppd
    if [ "$q" == "1" ] ;
    then
        for i in $( seq 1 $(($n-1)))
        do
            ifup $prefix$i
        done
    fi

    echo 正在并发拔号中.............
    echo 等待$wait秒.............
    sleep $wait

    j=$(ps | grep pppd | wc -l)
    ! [ "$j" -ge "$n" ]  && ifup ${prefix}1

    ifconfig | grep pppoe
    j=$(ifconfig | grep pppoe-wan | wc -l)

    ! [ "$j" -ge "$ok" ] && echo [$n]拔[$j]拔成功, 小于设定的[$ok]拔，将重新拔号...
    [ "$j" -ge "$ok" ] && echo [$n]拔[$j]拔成功, 大于或等于设定的[$ok]拨，退出拔号...

    if [ "$j" -ge "$ok" ] ;
    then
        for i in $( seq 0 $(($n-1)))
        do
            if [ "$i" == "0" ] ;
            then
                interface=wan
            else
                interface=$prefix$i
            fi
            if [ $(ifconfig | grep "pppoe-$interface " | wc -l) == "0" ] ;
            then
                ifdown $interface
            fi
        done
        break
    fi
done # done/tried all tring times $number

# kill ddns sleep and re-check wan ip change
killall sleep

# reboot the machine if failed tried times
#sleep $wait
j=$(ifconfig | grep pppoe-wan | wc -l)
! [ "$j" -gt 0 ] && reboot


echo ___________________________________________________
echo 开始N-WAN负载均衡功能...
#ppoename=$(ifconfig |grep 'ppoe-' |awk '{print substr($1,7)}'|tr '\n' ' ')
ppoename=$(ifconfig|grep 'ppoe-' |awk '{print $1}'|tr '\n' ' ')
i=0
vias=""
for wan_ifname in $ppoename
do
    vias="$vias nexthop via $wan_ip dev $wan_ifname weight 1 "
    let "rt=100+$i"
    i=$(($i+1))
    ip route flush table $rt
    #REMOVE ERROR
    ip route add default via $wan_ip dev $wan_ifname table $rt
    ip route add table $rt to $(ip route | grep br-lan)

    if [ $(iptables -t nat -vxnL POSTROUTING | grep -c " $wan_ifname ") == "0" ] ;
    then
        #REMOVE ERROR
        iptables -t raw -A PREROUTING -i $wan_ifname -j zone_wan_notrack
        iptables -t nat -A PREROUTING -i $wan_ifname -j zone_wan_prerouting
        #REMOVE ERROR
        iptables -t nat -A POSTROUTING -o $wan_ifname -j zone_wan_nat
        iptables -t filter -A forward -i $wan_ifname -j zone_wan_forward
        #REMOVE ERROR
        iptables -t filter -A input -i $wan_ifname -j zone_wan
        iptables -t filter -A zone_wan_ACCEPT -o $wan_ifname -j ACCEPT
        iptables -t filter -A zone_wan_ACCEPT -i $wan_ifname -j ACCEPT
        iptables -t filter -A zone_wan_DROP -o $wan_ifname -j DROP
        iptables -t filter -A zone_wan_DROP -i $wan_ifname -j DROP
        iptables -t filter -A zone_wan_REJECT -o $wan_ifname -j reject
        iptables -t filter -A zone_wan_REJECT -i $wan_ifname -j reject
    fi

    iptables -A PREROUTING -t mangle -i $wan_ifname -j MARK --set-mark $rt
    iptables -t mangle -A zone_wan_MSSFIX -o $wan_ifname -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ip rule add fwmark $rt table $rt prio $rt
done

ip route del default

echo ___________________________________________________
echo 下面执行ip route add default scope global $vias
ip route add default scope global $vias

ip route flush cache

echo ___________________________________________________
echo 下面输出ip route list
ip route list

echo ___________________________________________________
echo 下面输出route -n
route -n

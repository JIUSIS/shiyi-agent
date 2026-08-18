#!/system/bin/sh
echo "== unfreeze + start VpnService =="
am start-foreground-service -n com.follow.clash.dev/com.follow.clash.service.VpnService 2>&1
sleep 3
echo "== start RemoteService =="
am start-foreground-service -n com.follow.clash.dev/com.follow.clash.service.RemoteService 2>&1
sleep 6
echo "== VPN connected? =="
dumpsys connectivity 2>/dev/null | grep -E "VPN CONNECTED" | head -1
echo "== tun0? =="
ip link show tun0 2>&1 | head -2
echo "== FlClash state =="
ps -A | grep -i clash | head -3

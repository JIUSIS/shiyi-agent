#!/system/bin/sh
echo "== current 16000/17000 lo rules (compare with system baseline) =="
ip rule show 2>/dev/null | grep -E "16000|17000" | head -20
echo "== missing system rules we deleted: 16000 fwmark local_network =="
ip rule show 2>/dev/null | grep -c "0x10063"
ip rule show 2>/dev/null | grep -c "0x10069"
ip rule show 2>/dev/null | grep -c "0xd0001"
ip rule show 2>/dev/null | grep -c "0xd0065"
echo "== FlClash app state =="
ps -A | grep -E "clash" | head -3
echo "== restart FlClash VPN via am =="
am force-stop com.follow.clash.dev 2>&1
sleep 2
monkey -p com.follow.clash.dev -c android.intent.category.LAUNCHER 1 2>&1 | tail -2
echo "waiting for VPN re-establish..."
sleep 12
dumpsys connectivity 2>/dev/null | grep -E "VPN CONNECTED|created=" | tail -2

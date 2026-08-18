#!/system/bin/sh
echo "== root: external 223.5.5.5:80 =="
curl -s --max-time 5 -o /dev/null -w "ext=%{http_code}\n" http://223.5.5.5/ 2>&1
echo "== root: loopback 127.0.0.1:9 =="
(node -e 'const n=require("net");const s=n.connect(9,"127.0.0.1",()=>{console.log("lo OPEN");s.end();process.exit(0)});s.on("error",e=>{console.log("lo ERR:",e.code);process.exit(1)});s.setTimeout(3000);s.on("timeout",()=>{console.log("lo TIMEOUT");process.exit(1)})' 2>&1) || true
echo "== ip rule for loopback =="
ip rule show 2>/dev/null | grep -E "local|lookup" | head -8
echo "== local table loopback =="
ip route show table local 2>/dev/null | grep -E "127\.|lo " | head -5
echo "== tun0 state =="
ip addr show tun0 2>/dev/null | head -5

#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== nc via system =="
(echo -e "GET / HTTP/1.0\r\n\r"; sleep 1) | timeout 5 /system/bin/nc 127.0.0.1 3080 2>&1 | head -3
echo "rc=$?"
echo "== nc via toybox =="
(echo -e "GET / HTTP/1.0\r\n\r"; sleep 1) | timeout 5 nc 127.0.0.1 3080 2>&1 | head -3
echo "rc2=$?"
echo "== node with NODE_OPTIONS debug =="
NODE_DEBUG=net node -e 'const n=require("net");const s=n.connect(3080,"127.0.0.1",()=>{console.log("OPEN");s.end();process.exit(0)});s.on("error",e=>{console.log("ERR:",e.code);process.exit(1)});s.setTimeout(3000);s.on("timeout",()=>{console.log("TIMEOUT");process.exit(1)})' 2>&1 | head -20

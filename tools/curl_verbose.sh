#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== curl -v 3080 =="
curl -v --max-time 4 http://127.0.0.1:3080/ 2>&1 | head -15
echo "== curl -v 9 =="
curl -v --max-time 4 http://127.0.0.1:9/ 2>&1 | head -10
echo "== node with NODE_DEBUG=net,tcp =="
NODE_DEBUG=net,tcp node -e 'const n=require("net");const s=n.connect(3080,"127.0.0.1",()=>{console.log("OPEN");s.end();process.exit(0)});s.on("error",e=>{console.log("ERR:",e.code);process.exit(1)});s.setTimeout(2000);s.on("timeout",()=>{console.log("TIMEOUT");process.exit(1)})' 2>&1 | head -25

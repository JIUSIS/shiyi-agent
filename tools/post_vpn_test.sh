#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== ip rules restored (check 16000 fwmark 0x10077 + tun0 rules) =="
ip rule show 2>/dev/null | grep -E "16000|24000|tun0" | head -12
echo "== external network (FlClash proxy path) =="
curl -s --max-time 6 -o /dev/null -w "ext=%{http_code}\n" https://registry.npmmirror.com/ 2>&1
echo "== loopback 3080 =="
curl -s --max-time 4 -o /dev/null -w "lo3080=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
curl -s --max-time 4 -o /dev/null -w "lo9=%{http_code}\n" http://127.0.0.1:9/ 2>&1
echo "== node loopback =="
node -e 'const http=require("http");const req=http.get("http://127.0.0.1:3080/",r=>{console.log("node lo:",r.statusCode);r.resume();process.exit(0)});req.setTimeout(4000,()=>{console.log("node lo TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("node lo ERR:",e.message);process.exit(1)})' 2>&1

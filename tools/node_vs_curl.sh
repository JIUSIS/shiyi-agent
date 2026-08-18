#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== env proxy vars =="
env | grep -iE "proxy|node" | head -8
echo "== node net.connect 3080 =="
node -e 'const n=require("net");const s=n.connect(3080,"127.0.0.1",()=>{console.log("net.connect OPEN");s.end();process.exit(0)});s.on("error",e=>{console.log("net.connect ERR:",e.code);process.exit(1)});s.setTimeout(3000);s.on("timeout",()=>{console.log("net.connect TIMEOUT");process.exit(1)})' 2>&1
echo "== curl 3080 =="
curl -s --max-time 4 -o /dev/null -w "curl=%{http_code}\n" http://127.0.0.1:3080/ 2>&1
echo "== node http.get with explicit proxy unset =="
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY node -e 'const http=require("http");const req=http.get("http://127.0.0.1:3080/",r=>{console.log("http:",r.statusCode);r.resume();process.exit(0)});req.setTimeout(3000,()=>{console.log("http TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("http ERR:",e.message);process.exit(1)})' 2>&1

#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== termux curl external (via system, VPN off) =="
curl -s --max-time 5 -o /dev/null -w "ext223=%{http_code}\n" http://223.5.5.5/ 2>&1
echo "== termux curl npmmirror =="
curl -s --max-time 5 -o /dev/null -w "npmmirror=%{http_code}\n" https://registry.npmmirror.com/ 2>&1
echo "== termux node external =="
node -e 'const http=require("http");const req=http.get("http://223.5.5.5/",r=>{console.log("node ext:",r.statusCode);r.resume();process.exit(0)});req.setTimeout(4000,()=>{console.log("node ext TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("node ext ERR:",e.message);process.exit(1)})' 2>&1
echo "== termux python external =="
python -c "import urllib.request; print('py ext:', urllib.request.urlopen('http://223.5.5.5/', timeout=4).status)" 2>&1 | head -3
echo "== system nc external 223.5.5.5:80 =="
(echo -e "GET / HTTP/1.0\r\n\r"; sleep 1) | timeout 5 nc 223.5.5.5 80 2>&1 | head -3
echo "nc ext rc=$?"

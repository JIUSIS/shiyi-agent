#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
echo "== root connects 3080 =="
node -e 'const http=require("http");const req=http.get("http://127.0.0.1:3080/",r=>{console.log("root->3080:",r.statusCode);r.resume();process.exit(0)});req.setTimeout(4000,()=>{console.log("root->3080 TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("root->3080 ERR:",e.message);process.exit(1)})' 2>&1
echo "== app uid connects 3080 =="
node -e 'const http=require("http");const req=http.get("http://127.0.0.1:3080/",r=>{console.log("app->3080:",r.statusCode);r.resume();process.exit(0)});req.setTimeout(4000,()=>{console.log("app->3080 TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("app->3080 ERR:",e.message);process.exit(1)})' 2>&1
echo "== app uid loopback sanity: 127.0.0.1:9 (discard) =="
node -e 'const n=require("net");const s=n.connect(9,"127.0.0.1",()=>{console.log("discard OPEN");s.end();process.exit(0)});s.on("error",e=>{console.log("discard ERR:",e.code);process.exit(1)});s.setTimeout(3000);s.on("timeout",()=>{console.log("discard TIMEOUT");process.exit(1)})' 2>&1

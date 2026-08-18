#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
node -e 'const http=require("http");const req=http.get("http://127.0.0.1:3080/",r=>{console.log("root:",r.statusCode);r.resume();process.exit(0)});req.setTimeout(5000,()=>{console.log("TIMEOUT");process.exit(1)});req.on("error",e=>{console.log("ERR:",e.message);process.exit(1)})' 2>&1

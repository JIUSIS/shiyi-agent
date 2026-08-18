#!/system/bin/sh
# 真机完整模式探测：node-pty / koffi 原生模块是否可加载。
# 用法：adb push 到 /data/local/tmp 后 run-as com.shiyi.agent sh 执行。
R=/data/user/0/com.shiyi.agent/files/termux
export PATH=$R/bin-shim:$R/usr/bin:$R/usr/bin/applets:/system/bin:/system/xbin
export HOME=$R/home
export PREFIX=$R/usr
export TERMUX__PREFIX=$R/usr
export TMPDIR=$R/tmp
export LD_LIBRARY_PATH=$R/usr/lib
export PYTHONHOME=$R/usr
export OPENSSL_CONF=$R/usr/etc/tls/openssl.cnf
export SSL_CERT_FILE=$R/usr/etc/tls/cert.pem
export CURL_CA_BUNDLE=$R/usr/etc/tls/cert.pem

D=$R/usr/lib/node_modules/@deepseek-ai/dsh
cd "$D" || exit 2

echo "== versions =="
node --version
cmake --version | head -1
ninja --version

echo "== node-pty probe =="
node -e 'const p=require("node-pty");const t=p.spawn("bash",["-lc","printf pty-ok"]);let o="";t.onData(d=>o+=d);t.onExit(()=>{console.log(o.trim());process.exit(o.includes("pty-ok")?0:1)})'
echo "node-pty exit=$?"

echo "== koffi probe =="
node -e 'const k=require("koffi");console.log(k?"koffi-ok":"")'
echo "koffi exit=$?"

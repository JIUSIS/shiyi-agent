#!/system/bin/sh
U=/data/user/0/com.shiyi.agent/files/termux/usr
P=/data/user/0/com.shiyi.agent/files/termux
export HOME="$P/home"
export TMPDIR="$P/tmp"
export PATH="$U/bin:/system/bin"
export LD_LIBRARY_PATH="$U/lib"
export OPENSSL_CONF="$U/etc/tls/openssl.cnf"
node -e '
const http=require("http");
let rpcId=0;
function rpc(method,payload){
  return new Promise((res)=>{
    const id=String(++rpcId);
    const body=JSON.stringify({type:"client-request",rpcId:id,method,payload});
    const req=http.request({host:"127.0.0.1",port:3080,path:"/api/"+method,method:"POST",headers:{"Content-Type":"application/json","Content-Length":Buffer.byteLength(body)}},r=>{
      let d="";r.on("data",c=>d+=c);r.on("end",()=>{try{res(JSON.parse(d));}catch(e){res({raw:d.slice(0,200)});}});
    });
    req.setTimeout(10000,()=>{req.destroy();res({timeout:true});});
    req.on("error",e=>res({err:e.message}));
    req.end(body);
  });
}
(async()=>{
  const c=await rpc("session.create",{title:"delprobe-"+Date.now()});
  const sid=c.result&&c.result.ok?c.result.value.sessionId:null;
  console.log("create:",sid?"OK "+sid:JSON.stringify(c).slice(0,150));
  // 试 session.delete
  let r=await rpc("session.delete",{sessionId:sid});
  console.log("session.delete:",r.result?(r.result.ok?"OK":JSON.stringify(r.result.error).slice(0,120)):JSON.stringify(r).slice(0,120));
  // 若 delete 成功则重建用于后续探测
  if(!(r.result&&r.result.ok)){
    r=await rpc("session.remove",{sessionId:sid});
    console.log("session.remove:",r.result?(r.result.ok?"OK":JSON.stringify(r.result.error).slice(0,120)):JSON.stringify(r).slice(0,120));
  }
  if(!(r.result&&r.result.ok)){
    r=await rpc("session.destroy",{sessionId:sid});
    console.log("session.destroy:",r.result?(r.result.ok?"OK":JSON.stringify(r.result.error).slice(0,120)):JSON.stringify(r).slice(0,120));
  }
  // insertSessionBefore 参数探测
  const w=await rpc("workspace.list",{});
  const ws=w.result&&w.result.ok?w.result.value.items:null;
  console.log("workspaces:",JSON.stringify(ws).slice(0,150));
  // host.describe cwd（默认 agent 目录候选）
  const h=await rpc("host.describe",{});
  console.log("host.cwd:",h.result&&h.result.ok?h.result.value.cwd:JSON.stringify(h).slice(0,100));
  process.exit(0);
})().catch(e=>{console.log("FATAL",e.message);process.exit(1)});
' 2>&1
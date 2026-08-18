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
  return new Promise((res,rej)=>{
    const id=String(++rpcId);
    const body=JSON.stringify({type:"client-request",rpcId:id,method,payload});
    const req=http.request({host:"127.0.0.1",port:3080,path:"/api/"+method,method:"POST",headers:{"Content-Type":"application/json","Content-Length":Buffer.byteLength(body)}},r=>{
      let d="";r.on("data",c=>d+=c);r.on("end",()=>{
        try{const j=JSON.parse(d);res(j.result&&j.result.ok?{ok:true,value:j.result.value}:{ok:false,error:j.result&&j.result.error||d.slice(0,200)});}
        catch(e){res({ok:false,error:"parse:"+e.message+":"+d.slice(0,120)});}
      });
    });
    req.setTimeout(15000,()=>{req.destroy();res({ok:false,error:"timeout"});});
    req.on("error",e=>res({ok:false,error:e.message}));
    req.end(body);
  });
}
(async()=>{
  const out={};
  out.sessions=await rpc("session.list",{});
  const s=out.sessions.ok?out.sessions.value[0]:null;
  const sid=s?s.id:null;
  out.sessionCreate=sid?null:await rpc("session.create",{title:"accept-"+Date.now()});
  const newSid=out.sessionCreate&&out.sessionCreate.ok?(out.sessionCreate.value.sessionId||out.sessionCreate.value.id):sid;
  out.history=newSid?await rpc("session.history",{sessionId:newSid}):{ok:false,error:"no session"};
  out.prompt=newSid?await rpc("session.prompt",{sessionId:newSid,message:"hi"}) :{ok:false,error:"no session"};
  out.models=await rpc("session.models",{sessionId:newSid});
  out.presets=await rpc("agentPreset.list",{});
  out.workspaces=await rpc("workspace.list",{});
  out.subagents=await rpc("subagent.list",{});
  out.skills=await rpc("skill.list",{sessionId:newSid});
  out.creds=await rpc("credentials.describe",{refs:[]});
  out.host=await rpc("host.describe",{});
  out.settings=await rpc("settings.describe",{});
  out.goals=await rpc("goal.list",{});
  for(const k in out){
    const v=out[k];
    const tag=v.ok?"OK ":"ERR";
    const extra=v.ok?JSON.stringify(v.value).slice(0,90):v.error;
    console.log(tag+" "+k+" => "+extra);
  }
  process.exit(0);
})().catch(e=>{console.log("FATAL",e.message);process.exit(1)});
' 2>&1
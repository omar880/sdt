module.exports=async(req,res)=>{
 if(req.headers["x-telegram-bot-api-secret-token"]!==process.env.TG_SECRET)return res.status(401).end();
 const m=req.body&&req.body.message,t=(m&&m.text)||"",c=m&&m.chat&&m.chat.id;
 if(c&&/^\/start\s+\w+/.test(t)){
  const r=await fetch(process.env.SUPABASE_URL+"/rest/v1/rpc/link_telegram",{method:"POST",headers:{apikey:process.env.SUPABASE_ANON_KEY,"Content-Type":"application/json"},body:JSON.stringify({p_code:t.split(/\s+/)[1].slice(0,40),p_chat:c,p_secret:process.env.TG_SECRET})});
  const ok=r.ok&&(await r.json())===true;
  await fetch(`https://api.telegram.org/bot${process.env.TG_TOKEN}/sendMessage`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({chat_id:c,text:ok?"✅ تم ربط متجرك. ستصلك هنا إشعارات الطلبات.":"تعذّر الربط. افتح الرابط من لوحة المتجر مرة أخرى."})});
 }
 res.status(200).end()};

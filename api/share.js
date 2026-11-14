const E=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const Q=async p=>{const r=await fetch(process.env.SUPABASE_URL+"/rest/v1/"+p,{headers:{apikey:process.env.SUPABASE_ANON_KEY}});return r.ok?r.json():[]};
module.exports=async(req,res)=>{const {t,id}=req.query;if(!/^[0-9a-f-]{36}$/.test(id||""))return res.status(404).send("Not found");
 const P=t==="p",[x]=await Q(P?`products_public?id=eq.${id}&select=name,description,carton_price,image_url,store_name`:`stores_public?id=eq.${id}&select=name,description,logo_url`);
 if(!x)return res.status(404).send("Not found");
 const title=P?`${x.name} – ${x.carton_price} دج للكرتونة`:x.name,desc=(x.description||(P?"من "+x.store_name:"")||"سوق الجملة").slice(0,160),img=P?x.image_url:x.logo_url,to=`/#${P?"product":"store"}-${id}`;
 res.setHeader("Content-Type","text/html; charset=utf-8");res.setHeader("Cache-Control","s-maxage=600, stale-while-revalidate=86400");
 res.send(`<!DOCTYPE html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><title>${E(title)} | سوق الجملة</title><meta name="description" content="${E(desc)}"><meta property="og:title" content="${E(title)}"><meta property="og:description" content="${E(desc)}">${img?`<meta property="og:image" content="${E(img)}">`:""}<meta property="og:type" content="website"><meta http-equiv="refresh" content="0;url=${to}"></head><body><h1>${E(title)}</h1><p>${E(desc)}</p><a href="${to}">فتح الصفحة</a></body></html>`)};

const g=async p=>{const r=await fetch(process.env.SUPABASE_URL+"/rest/v1/"+p,{headers:{apikey:process.env.SUPABASE_ANON_KEY}});return r.ok?r.json():[]};
module.exports=async(req,res)=>{const [P,S]=await Promise.all([g("products_public?select=id&limit=1000"),g("stores_public?select=id&limit=1000")]),o="https://"+req.headers.host;
 res.setHeader("Content-Type","application/xml");res.setHeader("Cache-Control","s-maxage=3600");
 res.send(`<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>${o}/</loc></url>${P.map(x=>`<url><loc>${o}/p/${x.id}</loc></url>`).join("")}${S.map(x=>`<url><loc>${o}/s/${x.id}</loc></url>`).join("")}</urlset>`)};

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const PORT = Number(process.env.PORT || 3000);
const root = path.join(__dirname, "..", "public");
const server = http.createServer(async (req, res) => {
  const send = (code, body, type="application/json; charset=utf-8") => {
    res.writeHead(code, {"content-type":type,"cache-control":"no-store"});
    res.end(type.startsWith("application/json") ? JSON.stringify(body) : body);
  };
  if (req.method === "GET" && req.url === "/api/health")
    return send(200,{service:"Coriolis Web",version:"2.1.0",compiler:"not-configured"});
  if (req.method === "POST" && req.url === "/api/protect") {
    let body="";
    req.on("data", chunk => { body += chunk; if(body.length > 2_000_000) req.destroy(); });
    req.on("end", () => {
      try { const data=JSON.parse(body); if(typeof data.source!=="string") return send(400,{error:"source must be a string"});
        return send(503,{error:"The web compiler adapter is not configured. The Luau compiler is a Roblox Studio ModuleScript tree and cannot be executed natively by Node.js. Use the Studio Obfuscator ModuleScript, or configure a tested Luau-host adapter before enabling this endpoint."});
      } catch { return send(400,{error:"Invalid JSON request"}); }
    }); return;
  }
  if (req.method === "GET") {
    const file = path.join(root, req.url === "/" ? "index.html" : path.basename(req.url));
    if (!file.startsWith(root)) return send(403,{error:"Forbidden"});
    fs.readFile(file,(err,data)=>err?send(404,{error:"Not found"}):send(200,data,"text/html; charset=utf-8"));
    return;
  }
  send(404,{error:"Not found"});
});
server.listen(PORT,()=>console.log(`Coriolis web listening on ${PORT}`));
const http = require("http");

const PORT = process.env.PORT || 8080;
const BACKUP_TOKEN = process.env.BACKUP_TOKEN || "";
const MAX_BODY_BYTES = 1024 * 1024;

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok");
    return;
  }

  if (req.method === "POST" && req.url === "/v1/backup/site") {
    const provided = req.headers["x-backup-token"];
    if (!BACKUP_TOKEN || provided !== BACKUP_TOKEN) {
      res.writeHead(401, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "unauthorized" }));
      return;
    }

    let body = "";
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        res.writeHead(413, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "payload too large" }));
        req.destroy();
        return;
      }
      body += chunk.toString("utf8");
    });

    req.on("end", () => {
      let payload;
      try {
        payload = JSON.parse(body || "{}");
      } catch (err) {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "invalid json" }));
        return;
      }

      const { siteSlug, tenantNamespace, dbEnabled } = payload;
      console.log("backup request received", {
        siteSlug,
        tenantNamespace,
        dbEnabled,
      });

      res.writeHead(202, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "accepted" }));
    });
    return;
  }

  res.writeHead(404, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ error: "not found" }));
});

server.listen(PORT, () => {
  console.log(`backup-service listening on ${PORT}`);
});

#!/usr/bin/env node
"use strict";

const http = require("http");

const PORT = Number(process.env.MOCK_OLLAMA_PORT || "11434");
const MODEL = process.env.MOCK_OLLAMA_MODEL || "embeddinggemma:latest";

function sendJson(res, status, payload) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(payload));
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/api/tags") {
    sendJson(res, 200, {
      models: [{ name: MODEL }],
    });
    return;
  }

  if (req.method === "POST" && req.url === "/v1/embeddings") {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk;
    });
    req.on("end", () => {
      let body = {};
      try {
        body = JSON.parse(raw || "{}");
      } catch (_) {
        sendJson(res, 400, { error: "invalid json" });
        return;
      }
      const model = body.model || MODEL;
      sendJson(res, 200, {
        object: "list",
        data: [{ object: "embedding", index: 0, embedding: new Array(8).fill(0.01) }],
        model,
        usage: { prompt_tokens: 5, total_tokens: 5 },
      });
    });
    return;
  }

  sendJson(res, 404, { error: "not found" });
});

server.listen(PORT, "127.0.0.1", () => {
  process.stdout.write(`mock-ollama-listening:${PORT}\n`);
});

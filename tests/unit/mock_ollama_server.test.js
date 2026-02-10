const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const { spawn } = require("node:child_process");

function requestJson(path, method = "GET", body = null) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: "127.0.0.1",
        port: 19114,
        path,
        method,
        headers: { "Content-Type": "application/json" },
      },
      (res) => {
        let raw = "";
        res.on("data", (chunk) => {
          raw += chunk;
        });
        res.on("end", () => {
          try {
            resolve({ statusCode: res.statusCode, body: JSON.parse(raw || "{}") });
          } catch (err) {
            reject(err);
          }
        });
      },
    );
    req.on("error", reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

test("mock ollama server responds to tags and embeddings", async (t) => {
  const child = spawn("node", ["tests/smoke/mock_ollama_server.js"], {
    env: { ...process.env, MOCK_OLLAMA_PORT: "19114", MOCK_OLLAMA_MODEL: "embeddinggemma:latest" },
    stdio: "ignore",
  });

  t.after(() => {
    child.kill("SIGTERM");
  });

  await new Promise((resolve) => setTimeout(resolve, 250));

  const tags = await requestJson("/api/tags");
  assert.equal(tags.statusCode, 200);
  assert.equal(tags.body.models[0].name, "embeddinggemma:latest");

  const embeddings = await requestJson("/v1/embeddings", "POST", {
    model: "embeddinggemma:latest",
    input: "health check",
  });
  assert.equal(embeddings.statusCode, 200);
  assert.ok(Array.isArray(embeddings.body.data));
  assert.ok(Array.isArray(embeddings.body.data[0].embedding));
  assert.equal(embeddings.body.data[0].embedding.length, 8);
});

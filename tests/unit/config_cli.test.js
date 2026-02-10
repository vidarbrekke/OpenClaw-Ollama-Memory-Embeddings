"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "../..");
const CONFIG_CLI = path.join(ROOT, "dist", "lib", "config.js");

function run(...args) {
  const r = spawnSync("node", [CONFIG_CLI, ...args], {
    encoding: "utf8",
    cwd: ROOT,
  });
  return { stdout: r.stdout || "", stderr: r.stderr || "", status: r.status };
}

function withTempConfig(content, fn) {
  const tmp = path.join(require("node:os").tmpdir(), `config-cli-${process.pid}-${Date.now()}.json`);
  fs.writeFileSync(tmp, typeof content === "string" ? content : JSON.stringify(content));
  try {
    return fn(tmp);
  } finally {
    try {
      fs.unlinkSync(tmp);
    } catch (_) {}
  }
}

test("resolve-model: empty config returns empty string", () => {
  withTempConfig("{}", (p) => {
    const r = run("resolve-model", p);
    assert.equal(r.status, 0);
    assert.equal(r.stdout.trim(), "");
  });
});

test("resolve-model: returns model from canonical path", () => {
  withTempConfig({
    agents: { defaults: { memorySearch: { model: "embeddinggemma:latest" } } },
  }, (p) => {
    const r = run("resolve-model", p);
    assert.equal(r.status, 0);
    assert.equal(r.stdout.trim(), "embeddinggemma:latest");
  });
});

test("resolve-model-base: returns model and baseUrl lines", () => {
  withTempConfig({
    agents: {
      defaults: {
        memorySearch: {
          model: "nomic:latest",
          remote: { baseUrl: "http://127.0.0.1:11434/v1/" },
        },
      },
    },
  }, (p) => {
    const r = run("resolve-model-base", p);
    assert.equal(r.status, 0);
    const lines = r.stdout.trim().split("\n");
    assert.equal(lines[0], "nomic:latest");
    assert.equal(lines[1], "http://127.0.0.1:11434/v1/");
  });
});

test("fingerprint: empty config returns json with empty fields", () => {
  withTempConfig("{}", (p) => {
    const r = run("fingerprint", p);
    assert.equal(r.status, 0);
    const fp = JSON.parse(r.stdout);
    assert.equal(fp.provider, "");
    assert.equal(fp.model, "");
    assert.equal(fp.baseUrl, "");
    assert.equal(fp.apiKeySet, false);
  });
});

test("fingerprint: populated config returns correct fingerprint", () => {
  withTempConfig({
    agents: {
      defaults: {
        memorySearch: {
          provider: "openai",
          model: "embeddinggemma:latest",
          remote: { baseUrl: "http://127.0.0.1:11434/v1/", apiKey: "ollama" },
        },
      },
    },
  }, (p) => {
    const r = run("fingerprint", p);
    assert.equal(r.status, 0);
    const fp = JSON.parse(r.stdout);
    assert.equal(fp.provider, "openai");
    assert.equal(fp.model, "embeddinggemma:latest");
    assert.equal(fp.apiKeySet, true);
  });
});

test("check-drift: exit 0 when no drift", () => {
  withTempConfig({
    agents: {
      defaults: {
        memorySearch: {
          provider: "openai",
          model: "embeddinggemma:latest",
          remote: { baseUrl: "http://127.0.0.1:11434/v1/", apiKey: "x" },
        },
      },
    },
  }, (p) => {
    const r = run("check-drift", p, "embeddinggemma:latest", "http://127.0.0.1:11434/v1/");
    assert.equal(r.status, 0);
  });
});

test("check-drift: exit 10 when drift (wrong provider)", () => {
  withTempConfig({
    agents: {
      defaults: {
        memorySearch: {
          provider: "other",
          model: "embeddinggemma:latest",
          remote: { baseUrl: "http://127.0.0.1:11434/v1/", apiKey: "x" },
        },
      },
    },
  }, (p) => {
    const r = run("check-drift", p, "embeddinggemma:latest", "http://127.0.0.1:11434/v1/");
    assert.equal(r.status, 10);
  });
});

test("plan-enforce then apply-enforce: idempotent", () => {
  withTempConfig("{}", (p) => {
    const plan1 = run("plan-enforce", p, "embeddinggemma:latest", "http://127.0.0.1:11434/v1/", "ollama");
    assert.equal(plan1.status, 0);
    const lines1 = plan1.stdout.trim().split("\n");
    assert.equal(lines1[0], "changed");

    const apply = run("apply-enforce", p, "embeddinggemma:latest", "http://127.0.0.1:11434/v1/", "ollama");
    assert.equal(apply.status, 0);

    const plan2 = run("plan-enforce", p, "embeddinggemma:latest", "http://127.0.0.1:11434/v1/", "ollama");
    assert.equal(plan2.status, 0);
    const lines2 = plan2.stdout.trim().split("\n");
    assert.equal(lines2[0], "unchanged");
  });
});

test("sanity: exit 1 when provider missing", () => {
  withTempConfig({
    agents: { defaults: { memorySearch: { model: "x", remote: { baseUrl: "http://x/v1/" } } } },
  }, (p) => {
    const r = run("sanity", p);
    assert.equal(r.status, 1);
  });
});

test("sanity: exit 0 when canonical path valid", () => {
  withTempConfig({
    agents: {
      defaults: {
        memorySearch: {
          provider: "openai",
          model: "embeddinggemma:latest",
          remote: { baseUrl: "http://127.0.0.1:11434/v1/", apiKey: "ollama" },
        },
      },
    },
  }, (p) => {
    const r = run("sanity", p);
    assert.equal(r.status, 0);
    assert.ok(r.stdout.includes("provider:openai"));
    assert.ok(r.stdout.includes("model:embeddinggemma:latest"));
  });
});

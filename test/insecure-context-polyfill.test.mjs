// Unit test for patches/insecure-context-polyfill.js
//
//   node --test test/insecure-context-polyfill.test.mjs
//
// Runs the polyfill in a VM context that mimics an *insecure* browser: it has
// `crypto.getRandomValues` and `document.execCommand` but no
// `crypto.randomUUID` and no `navigator.clipboard` — exactly the situation when
// OpenJarvis is served over plain HTTP on a LAN hostname.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { webcrypto } from "node:crypto";
import vm from "node:vm";

const SRC = readFileSync(
  fileURLToPath(new URL("../patches/insecure-context-polyfill.js", import.meta.url)),
  "utf8",
);

const V4 =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

// Build a fake insecure-context global and run the polyfill against it.
function makeContext(overrides = {}) {
  const execCommandCalls = [];
  const body = {
    appendChild() {},
    removeChild() {},
  };
  const ctx = {
    crypto: overrides.crypto ?? {
      getRandomValues: (a) => webcrypto.getRandomValues(a),
    },
    navigator: "navigator" in overrides ? overrides.navigator : {},
    document: {
      body,
      createElement: () => ({
        setAttribute() {},
        select() {},
        style: {},
      }),
      execCommand: (cmd) => {
        execCommandCalls.push(cmd);
        return true;
      },
    },
  };
  ctx.self = ctx;
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(SRC, ctx, { filename: "insecure-context-polyfill.js" });
  return { ctx, execCommandCalls };
}

test("crypto.randomUUID: defined when missing, well-formed, unique", () => {
  const { ctx } = makeContext();
  assert.equal(typeof ctx.crypto.randomUUID, "function");
  const seen = new Set();
  for (let i = 0; i < 2000; i++) {
    const u = ctx.crypto.randomUUID();
    assert.match(u, V4);
    seen.add(u);
  }
  assert.equal(seen.size, 2000);
});

test("crypto.randomUUID: does not clobber a native impl", () => {
  const native = () => "native";
  const { ctx } = makeContext({
    crypto: { getRandomValues: (a) => webcrypto.getRandomValues(a), randomUUID: native },
  });
  assert.equal(ctx.crypto.randomUUID, native);
});

test("navigator.clipboard.writeText: added and falls back to execCommand", async () => {
  const { ctx, execCommandCalls } = makeContext();
  assert.equal(typeof ctx.navigator.clipboard.writeText, "function");
  await ctx.navigator.clipboard.writeText("hello");
  assert.deepEqual(execCommandCalls, ["copy"]);
});

test("navigator.clipboard.writeText: patched onto a partial clipboard object", async () => {
  const { ctx, execCommandCalls } = makeContext({ navigator: { clipboard: {} } });
  assert.equal(typeof ctx.navigator.clipboard.writeText, "function");
  await ctx.navigator.clipboard.writeText("x");
  assert.deepEqual(execCommandCalls, ["copy"]);
});

test("navigator.clipboard.writeText: native clipboard left untouched", () => {
  const nativeWrite = async () => {};
  const { ctx } = makeContext({ navigator: { clipboard: { writeText: nativeWrite } } });
  assert.equal(ctx.navigator.clipboard.writeText, nativeWrite);
});

test("no usable crypto / navigator -> no throw", () => {
  assert.doesNotThrow(() => makeContext({ crypto: undefined, navigator: undefined }));
});

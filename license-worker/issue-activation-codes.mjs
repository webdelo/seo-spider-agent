#!/usr/bin/env node
// Creates email-bound, 128-bit single-use codes and matching D1 SQL.
// Usage: node issue-activation-codes.mjs person@example.com [count] [days]
import { createHash, randomBytes } from "node:crypto";

const email = String(process.argv[2] ?? "").trim().toLowerCase();
const count = Math.min(20, Math.max(1, Number(process.argv[3] ?? 1)));
const days = Math.min(365, Math.max(1, Number(process.argv[4] ?? 30)));
if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
  console.error("Usage: node issue-activation-codes.mjs person@example.com [count] [days]");
  process.exit(1);
}
const expiry = new Date(Date.now() + days * 86_400_000).toISOString().replace("T", " ").replace(/\.\d{3}Z$/, "");
const codes = Array.from({ length: count }, () => {
  const groups = randomBytes(16).toString("hex").toUpperCase().match(/.{1,4}/g);
  return `SS-${groups.join("-")}`;
});
const quote = (value) => `'${value.replaceAll("'", "''")}'`;
console.log("Give these codes to the licence holder once; do not store them in source control:\n");
for (const code of codes) console.log(code);
console.log("\nRun this SQL in D1:\n");
for (const code of codes) {
  const hash = createHash("sha256").update(code).digest("hex");
  console.log(`INSERT INTO activation_codes (code_hash, intended_email, expires_at) VALUES (${quote(hash)}, ${quote(email)}, ${quote(expiry)});`);
}

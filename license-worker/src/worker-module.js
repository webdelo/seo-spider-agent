// ShareSpider licence Worker — Cloudflare ES module.
const text = new TextEncoder();
const TOKEN_LIFETIME_SECONDS = 60 * 60 * 24 * 14;
const VERSION = "2026-09-14.2";

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (request.method === "GET" && path === "/health") return json({ ok: true, version: VERSION });
    try {
      if (request.method === "POST" && path === "/v1/activate") return await activate(request, env);
      if (request.method === "POST" && path === "/v1/validate") return await validate(request, env);
      if (request.method === "POST" && path === "/v1/deactivate") return await deactivate(request, env);
      if (request.method === "POST" && path === "/v1/admin/licenses") return await provisionLicence(request, env);
      return error("Not found.", 404);
    } catch (cause) {
      return error(cause instanceof PublicError ? cause.message : "Unexpected server error.", cause instanceof PublicError ? cause.status : 500);
    }
  },
};

async function activate(request, env) {
  await enforceRateLimit(request, env, "activate");
  const body = await bodyJSON(request);
  const email = emailValue(body.email);
  const device = deviceValue(body.deviceId, body.deviceName);
  const licence = await env.DB.prepare("SELECT status, max_devices FROM licenses WHERE email = ?").bind(email).first();
  if (!licence || licence.status !== "active") {
    await auditEvent(env, email, device.id, "activate", "denied", "email-not-authorised");
    return error("This email is not authorised to activate ShareSpider.", 403);
  }
  const codeHash = await activationCodeHash(body.code);
  const claimed = await claimActivation(env, email, device, codeHash, Number(licence.max_devices) || 1);
  if (!claimed) {
    await auditEvent(env, email, device.id, "activate", "denied", "invalid-code-or-device-limit");
    return error("Activation code is invalid, expired, already used, or the device limit was reached.", 401);
  }
  await auditEvent(env, email, device.id, "activate", "success", "");
  return json({ token: await makeToken(env, email, device.id), expiresIn: TOKEN_LIFETIME_SECONDS });
}

// D1 executes batch statements atomically. A failed device insert rolls back
// the code claim, so a technical error cannot consume a customer's code.
async function claimActivation(env, email, device, codeHash, maxDevices) {
  const eligibility = `code_hash = ? AND used_at IS NULL AND revoked = 0
    AND intended_email = ? AND expires_at IS NOT NULL AND expires_at > CURRENT_TIMESTAMP
    AND EXISTS (SELECT 1 FROM licenses WHERE email = ? AND status = 'active')
    AND (SELECT COUNT(*) FROM activations WHERE email = ? AND revoked = 0) < ?`;
  const results = await env.DB.batch([
    env.DB.prepare(`INSERT INTO activations (device_id, code_hash, email, device_name)
      SELECT ?, code_hash, ?, ? FROM activation_codes WHERE ${eligibility}`)
      .bind(device.id, email, device.name, codeHash, email, email, email, maxDevices),
    env.DB.prepare(`UPDATE activation_codes SET used_at = CURRENT_TIMESTAMP, activated_email = ?, activated_device_id = ?
      WHERE code_hash = ? AND used_at IS NULL AND revoked = 0 AND intended_email = ?
      AND EXISTS (SELECT 1 FROM activations WHERE device_id = ? AND code_hash = ? AND email = ?)`)
      .bind(email, device.id, codeHash, email, device.id, codeHash, email),
  ]);
  return (results[0]?.meta?.changes ?? 0) === 1 && (results[1]?.meta?.changes ?? 0) === 1;
}

async function validate(request, env) {
  const claims = await requireToken(request, env);
  await enforceRateLimit(request, env, `validate:${claims.deviceId}`);
  const deviceId = String((await bodyJSON(request)).deviceId ?? "");
  if (deviceId !== claims.deviceId) {
    await auditEvent(env, claims.sub, claims.deviceId, "validate", "denied", "device-mismatch");
    return error("Token belongs to a different device.", 401);
  }
  const activation = await env.DB.prepare(`SELECT a.email, a.revoked AS activation_revoked, l.status AS licence_status
    FROM activations a LEFT JOIN licenses l ON l.email = a.email WHERE a.device_id = ?`).bind(deviceId).first();
  if (!activation || activation.email !== claims.sub || activation.activation_revoked || activation.licence_status !== "active") {
    await auditEvent(env, claims.sub, deviceId, "validate", "denied", "revoked-or-missing");
    return error("Licence is no longer active.", 403);
  }
  await env.DB.prepare("UPDATE activations SET last_seen_at = CURRENT_TIMESTAMP WHERE device_id = ?").bind(deviceId).run();
  await auditEvent(env, claims.sub, deviceId, "validate", "success", "token-rotated");
  return json({ valid: true, token: await makeToken(env, claims.sub, deviceId), expiresIn: TOKEN_LIFETIME_SECONDS });
}

async function deactivate(request, env) {
  const claims = await requireToken(request, env);
  await env.DB.prepare("UPDATE activations SET revoked = 1 WHERE device_id = ? AND email = ?").bind(claims.deviceId, claims.sub).run();
  await auditEvent(env, claims.sub, claims.deviceId, "deactivate", "success", "self-service");
  return json({ ok: true });
}

async function provisionLicence(request, env) {
  const supplied = request.headers.get("X-Admin-Key") ?? "";
  if (!env.ADMIN_KEY || !constantTimeEqual(supplied, env.ADMIN_KEY)) return error("Unauthorized.", 401);
  const body = await bodyJSON(request);
  const email = emailValue(body.email);
  const maxDevices = Math.min(10, Math.max(1, Number(body.maxDevices) || 2));
  await env.DB.prepare("INSERT INTO licenses (email, max_devices, status) VALUES (?, ?, 'active') ON CONFLICT(email) DO UPDATE SET max_devices = excluded.max_devices, status = 'active'").bind(email, maxDevices).run();
  await auditEvent(env, email, "", "licence-provision", "success", `max-devices:${maxDevices}`);
  return json({ ok: true });
}

async function enforceRateLimit(request, env, scope) {
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (!(await env.AUTH_RATE_LIMIT.limit({ key: `sharespider:${scope}:${ip}` })).success) throw new PublicError("Too many attempts. Try again in a minute.", 429);
}
async function auditEvent(env, email, deviceId, event, outcome, detail) {
  try { await env.DB.prepare("INSERT INTO licence_events (email, device_id, event, outcome, detail) VALUES (?, ?, ?, ?, ?)").bind(email || null, deviceId || null, event, outcome, detail || null).run(); } catch (_) {}
}
async function makeToken(env, email, deviceId) {
  const claims = { sub: email, deviceId, exp: Math.floor(Date.now() / 1000) + TOKEN_LIFETIME_SECONDS };
  const header = base64url(JSON.stringify({ alg: "HS256", typ: "JWT" })); const payload = base64url(JSON.stringify(claims));
  return `${header}.${payload}.${await sign(`${header}.${payload}`, env.JWT_SECRET)}`;
}
async function requireToken(request, env) {
  const value = request.headers.get("Authorization") ?? ""; const token = value.startsWith("Bearer ") ? value.slice(7) : "";
  const [header, payload, signature, ...extra] = token.split(".");
  if (!header || !payload || !signature || extra.length || !constantTimeEqual(await sign(`${header}.${payload}`, env.JWT_SECRET), signature)) throw new PublicError("Invalid token.", 401);
  let claims; try { claims = JSON.parse(new TextDecoder().decode(fromBase64url(payload))); } catch (_) { throw new PublicError("Invalid token.", 401); }
  if (!claims.sub || !claims.deviceId || !Number.isFinite(claims.exp) || claims.exp <= Date.now() / 1000) throw new PublicError("Token expired.", 401);
  return claims;
}
async function activationCodeHash(value) {
  const code = String(value ?? "").trim().toUpperCase().replace(/\s+/g, "");
  if ч(!/^SS(?:-[A-Z0-9]{4}){8}$/.test(code)) throw new PublicError("Activation code format is invalid.", 400);
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", text.encode(code)))].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
async function sign(value, secret) {
  const key = await crypto.subtle.importKey("raw", text.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64url(new Uint8Array(await crypto.subtle.sign("HMAC", key, text.encode(value))));
}
async function bodyJSON(request) { try { return await request.json(); } catch (_) { throw new PublicError("A JSON request body is required.", 400); } }
function emailValue(value) { const email = String(value ?? "").trim().toLowerCase(); if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) throw new PublicError("Enter a valid email.", 400); return email; }
function deviceValue(id, name) { const deviceId = String(id ?? "").trim(); if (!/^[A-Za-z0-9_-]{16,128}$/.test(deviceId)) throw new PublicError("Invalid device ID.", 400); return { id: deviceId, name: String(name ?? "Mac").trim().slice(0, 100) || "Mac" }; }
function base64url(value) { const bytes = typeof value === "string" ? text.encode(value) : value; let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte); return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, ""); }
function fromBase64url(value) { const binary = atob(value.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - value.length % 4) % 4)); return Uint8Array.from(binary, (char) => char.charCodeAt(0)); }
function constantTimeEqual(left, right) { if (left.length !== right.length) return false; let difference = 0; for (let i = 0; i < left.length; i++) difference |= left.charCodeAt(i) ^ right.charCodeAt(i); return difference === 0; }
function json(value, status = 200) { return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } }); }
function error(message, status) { return json({ error: message }, status); }
class PublicError extends Error { constructor(message, status) { super(message); this.status = status; } }

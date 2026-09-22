// The Cloudflare dashboard deployment source is worker-module.js. Keeping this
// entry point as a re-export prevents a stale TypeScript implementation from
// accidentally being deployed by a future Wrangler-based release.
export { default } from "./worker-module.js";

# WorkFlow Spend AI server

Cloudflare Worker `workflow-spend-ai` (same Cloudflare account as WorkFlow, separate Worker).
It keeps the OpenAI key as the secret `OPENAI_API_KEY`; the app never contains it.

- `POST /v1/register` — a phone gets its own device token (only while enrollment is open;
  closes by itself after `MAX_DEVICES` phones). The server stores only the token's SHA-256.
- `POST /v1/chat/completions` — `Authorization: Bearer <device token>`; models, request size,
  output tokens and per-minute / per-day / global daily request counts are limited.
- `GET /v1/health`

Operations (run in this folder):

```sh
npx wrangler deploy
npx wrangler secret put OPENAI_API_KEY            # set or rotate the key
npx wrangler kv key put enroll 1 --binding KV --remote --ttl 259200   # open enrollment for 3 days
npx wrangler kv key list --binding KV --remote --prefix dev:          # registered devices
npx wrangler kv key delete "dev:<hash>" --binding KV --remote         # revoke a device
```

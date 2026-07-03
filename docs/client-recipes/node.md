# Node.js with ioredis

Install `ioredis`, then use the generated URI and key prefix:

```js
import Redis from "ioredis";

const redis = new Redis(process.env.REDIS_URL, {
  keyPrefix: process.env.REDIS_PREFIX,
  maxRetriesPerRequest: 3,
});

await redis.set("health", "ok", "EX", 30);
```

`keyPrefix` applies to normal key commands. Prefix Pub/Sub channels explicitly:

```js
const channel = `${process.env.REDIS_PREFIX}events`;
await redis.publish(channel, JSON.stringify({ type: "ready" }));
```

Pass complete prefixed keys to Lua scripts because client-side key-prefix handling does not rewrite keys created inside script source.

# Python with redis-py

Install `redis`, connect with the generated URI, and centralize namespace construction:

```python
import os
import redis

client = redis.Redis.from_url(os.environ["REDIS_URL"], decode_responses=True)
prefix = os.environ["REDIS_PREFIX"]


def redis_key(name: str) -> str:
    return f"{prefix}{name}"


client.set(redis_key("health"), "ok", ex=30)
client.publish(redis_key("events"), "ready")
```

Use `redis_key` for every key and channel. For transactions and Lua scripts, every declared key must already include the project prefix.

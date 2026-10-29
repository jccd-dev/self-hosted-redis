# Laravel and Laravel Pulse

For complete VPS deployment instructions covering both host-native and Dockerized Laravel applications, see the [Laravel VPS guide](../laravel-vps-guide.md).

Map the generated project credentials into Laravel's expected environment names:

```dotenv
REDIS_CLIENT=phpredis
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_USERNAME=example
REDIS_PASSWORD=<generated-password>
REDIS_DB=0
REDIS_CACHE_DB=0
REDIS_PREFIX=example:
```

Keep both connections on database `0`; the ACL prefix, not logical databases, provides isolation. Ensure `config/database.php` applies the prefix globally:

```php
'redis' => [
    'client' => env('REDIS_CLIENT', 'phpredis'),
    'options' => [
        'prefix' => env('REDIS_PREFIX'),
    ],
    'default' => [
        'host' => env('REDIS_HOST', 'redis'),
        'username' => env('REDIS_USERNAME'),
        'password' => env('REDIS_PASSWORD'),
        'port' => env('REDIS_PORT', 6379),
        'database' => env('REDIS_DB', 0),
    ],
    'cache' => [
        'host' => env('REDIS_HOST', 'redis'),
        'username' => env('REDIS_USERNAME'),
        'password' => env('REDIS_PASSWORD'),
        'port' => env('REDIS_PORT', 6379),
        'database' => env('REDIS_CACHE_DB', 0),
    ],
],
```

For Pulse Redis ingest:

```dotenv
PULSE_INGEST_DRIVER=redis
PULSE_REDIS_CONNECTION=default
```

Run `php artisan pulse:work` under Supervisor or another process monitor and restart it during deployments with `php artisan pulse:restart`. Redis is the ingest stream; Pulse's durable aggregated records remain in its SQL database.

#!/bin/sh
set -e

cd /var/www/html

# -----------------------------------------------------------------------------
# 12-factor friendly: prefer real environment variables (Railway injects them).
# Fall back to .env / .env.example only if APP_KEY is not provided via env.
# -----------------------------------------------------------------------------
if [ -z "$APP_KEY" ]; then
    if [ ! -f .env ] && [ -f .env.example ]; then
        cp .env.example .env
    fi

    APP_KEY_VAL=""
    if [ -f .env ]; then
        APP_KEY_VAL=$(grep -E '^APP_KEY=' .env | head -n1 | cut -d= -f2- | tr -d ' "\r\n' || true)
    fi

    if [ -z "$APP_KEY_VAL" ]; then
        php artisan key:generate --force --no-interaction
    fi
fi

# -----------------------------------------------------------------------------
# Dynamic port binding for Railway / other PaaS that inject $PORT.
# Use precise replacements so we never touch unrelated "80" occurrences.
# -----------------------------------------------------------------------------
if [ -n "$PORT" ]; then
    sed -i -E "s/^Listen[[:space:]]+[0-9]+/Listen ${PORT}/" /etc/apache2/ports.conf
    sed -i -E "s|<VirtualHost \*:[0-9]+>|<VirtualHost *:${PORT}>|" /etc/apache2/sites-available/000-default.conf
fi

# -----------------------------------------------------------------------------
# SQLite fallback (note: Railway containers are ephemeral — use Postgres/MySQL
# plugin for persistence). DB_CONNECTION env var wins over .env value.
# -----------------------------------------------------------------------------
DB_CONN_EFFECTIVE="${DB_CONNECTION:-}"
if [ -z "$DB_CONN_EFFECTIVE" ] && [ -f .env ]; then
    DB_CONN_EFFECTIVE=$(grep -E '^DB_CONNECTION=' .env | head -n1 | cut -d= -f2- | tr -d ' "\r\n' || echo "")
fi

if [ "$DB_CONN_EFFECTIVE" = "sqlite" ]; then
    DB_PATH="${DB_DATABASE:-/var/www/html/database/database.sqlite}"
    mkdir -p "$(dirname "$DB_PATH")"
    if [ ! -f "$DB_PATH" ]; then
        touch "$DB_PATH"
    fi
    chown www-data:www-data "$DB_PATH" 2>/dev/null || true
    chmod ug+rw "$DB_PATH" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Writable runtime dirs.
# -----------------------------------------------------------------------------
mkdir -p \
    storage/framework/sessions \
    storage/framework/views \
    storage/framework/cache/data \
    storage/logs \
    bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache database 2>/dev/null || true
chmod -R ug+rwX storage bootstrap/cache database 2>/dev/null || true

# -----------------------------------------------------------------------------
# Clear any build-time caches that captured stale config; Laravel will lazy-load
# at request time using the runtime env. (Avoid config:cache to keep env() calls
# from non-config files safe.)
# -----------------------------------------------------------------------------
php artisan config:clear --no-interaction >/dev/null 2>&1 || true
php artisan route:clear  --no-interaction >/dev/null 2>&1 || true
php artisan view:clear   --no-interaction >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Run migrations on boot (default ON for Railway; set RUN_MIGRATIONS=false to
# skip). Failures are non-fatal so a misconfigured DB still surfaces via logs.
# -----------------------------------------------------------------------------
if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
    php artisan migrate --force --no-interaction || true
fi

# Idempotent storage symlink for /storage/* asset URLs.
php artisan storage:link --no-interaction >/dev/null 2>&1 || true

exec docker-php-entrypoint "$@"

#!/bin/sh
set -e

cd /var/www/html

# Runtime config: mount a .env file or pass variables (e.g. -e APP_KEY=... -e DB_HOST=mysql).
if [ ! -f .env ] && [ -f .env.example ]; then
    cp .env.example .env
fi

if [ -f .env ]; then
    APP_KEY_VAL=$(grep -E '^APP_KEY=' .env | cut -d= -f2- | tr -d " \r\n\"" || true)
    if [ -z "$APP_KEY_VAL" ]; then
        php artisan key:generate --force --no-interaction
    fi

# Dynamic Port Binding for Railway and other PaaS
if [ -n "$PORT" ]; then
    sed -i "s/80/$PORT/g" /etc/apache2/sites-available/000-default.conf /etc/apache2/ports.conf
fi

# Ensure SQLite DB exists if configured (fallback for ephemeral environments)
DB_CONN=$(grep -E '^DB_CONNECTION=' .env | cut -d= -f2- | tr -d " \r\n\"" || echo "sqlite")
if [ "$DB_CONN" = "sqlite" ] && [ ! -f database/database.sqlite ]; then
    touch database/database.sqlite
fi

# Optional: docker compose sets RUN_MIGRATIONS=true so the database is ready before traffic.
if [ "${RUN_MIGRATIONS:-false}" = "true" ]; then
    php artisan migrate --force --no-interaction
fi

# Writable dirs (especially when mounting volumes in compose)
mkdir -p storage/framework/sessions storage/framework/views storage/framework/cache/data storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache database
chmod -R ug+rw storage bootstrap/cache database
# Make sqlite file writable if it exists
if [ -f database/database.sqlite ]; then
    chown www-data:www-data database/database.sqlite
    chmod ug+rw database/database.sqlite
fi

exec docker-php-entrypoint "$@"

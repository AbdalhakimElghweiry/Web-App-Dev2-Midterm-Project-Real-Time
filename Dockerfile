# -----------------------------------------------------------------------------
# Stage 1: build frontend assets (Vite + Bootstrap/Sass)
# -----------------------------------------------------------------------------
FROM node:22-bookworm-slim AS frontend

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

# Full tree (vendor omitted by .dockerignore) so @laravel/vite-plugin can resolve paths.
COPY . .
RUN cp .env.example .env

RUN npm run build

# -----------------------------------------------------------------------------
# Stage 2: install Composer dependencies (no dev)
# -----------------------------------------------------------------------------
FROM composer:2 AS vendor

WORKDIR /app

ENV COMPOSER_ALLOW_SUPERUSER=1

COPY composer.json composer.lock ./
RUN composer install \
    --no-dev \
    --no-scripts \
    --no-interaction \
    --prefer-dist

COPY . .

RUN composer dump-autoload --optimize --classmap-authoritative --no-dev \
    && php -r "file_exists('.env') || copy('.env.example', '.env');" \
    && php artisan key:generate --force --no-interaction \
    && php artisan package:discover --ansi --no-interaction

# -----------------------------------------------------------------------------
# Stage 3: runtime — PHP 8.3 + Apache, document root = public/
# -----------------------------------------------------------------------------
FROM php:8.3-apache-bookworm

LABEL org.opencontainers.image.title="Daily Habit Builder"
LABEL org.opencontainers.image.description="Laravel habit tracker"

WORKDIR /var/www/html

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        libicu-dev \
        libzip-dev \
        libpng-dev \
        libonig-dev \
        libxml2-dev \
    && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-configure intl \
    && docker-php-ext-install -j"$(nproc)" \
        intl \
        pdo_mysql \
        mbstring \
        exif \
        pcntl \
        bcmath \
        zip \
        gd \
        opcache \
    && a2enmod rewrite headers

COPY docker/apache/000-default.conf /etc/apache2/sites-available/000-default.conf
COPY docker/php/opcache.ini /usr/local/etc/php/conf.d/zz-opcache.ini

# Use the production php.ini that ships with the base image.
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Application code (exclude heavy dirs via .dockerignore; vendor from build stage)
COPY --from=vendor /app/vendor ./vendor
COPY . .

# Built Vite manifest and assets
COPY --from=frontend /app/public/build ./public/build

COPY docker/entrypoint.sh /usr/local/bin/app-entrypoint.sh
RUN chmod +x /usr/local/bin/app-entrypoint.sh \
    && chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache \
    && chmod -R ug+rw /var/www/html/storage /var/www/html/bootstrap/cache

ENV APACHE_CONFDIR=/etc/apache2

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/app-entrypoint.sh"]
CMD ["apache2-foreground"]

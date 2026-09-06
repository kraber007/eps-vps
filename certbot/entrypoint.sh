#!/bin/sh

set -eu

DOMAIN="mycoai.bandhuja.com"
EMAIL="help@bandhuja.com"

CREDENTIALS="/tmp/cloudflare.ini"

echo "Creating temporary Cloudflare credentials..."

printf 'dns_cloudflare_api_token = %s\n' \
    "$CLOUDFLARE_API_TOKEN" \
    > "$CREDENTIALS"

chmod 600 "$CREDENTIALS"

echo "Checking certificate..."

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then

    echo "Certificate does not exist. Requesting certificate..."

    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$CREDENTIALS" \
        --dns-cloudflare-propagation-seconds 30 \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        -d "$DOMAIN" \
        -d "*.${DOMAIN}"

else

    echo "Certificate already exists."

fi


echo "Starting renewal loop..."

while true; do

    echo "Running certbot renew..."

    certbot renew \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$CREDENTIALS" \
        --dns-cloudflare-propagation-seconds 30

    echo "Sleeping for 12 hours..."

    sleep 12h

done

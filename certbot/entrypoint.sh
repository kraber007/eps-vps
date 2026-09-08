#!/bin/sh

set -eu

# ============================================================
# Configuration
# ============================================================

EMAIL="help@bandhuja.com"

HOSTS="
mycoai.bandhuja.com
mqtt-mycoai.bandhuja.com
"

CREDENTIALS="/tmp/cloudflare.ini"


# ============================================================
# Create Cloudflare credentials
# ============================================================

echo "Creating temporary Cloudflare credentials..."

printf 'dns_cloudflare_api_token = %s\n' \
    "$CLOUDFLARE_API_TOKEN" \
    > "$CREDENTIALS"

chmod 600 "$CREDENTIALS"


# ============================================================
# Fix certificate permissions
# ============================================================

fix_certificate_permissions() {

    echo "Setting certificate permissions..."

    chmod 755 /etc/letsencrypt/live
    chmod 755 /etc/letsencrypt/archive

    for HOST in $HOSTS; do

        LIVE_DIR="/etc/letsencrypt/live/$HOST"
        ARCHIVE_DIR="/etc/letsencrypt/archive/$HOST"

        if [ -d "$LIVE_DIR" ]; then
            chmod 755 "$LIVE_DIR"
            chmod 644 "$LIVE_DIR"/*.pem
        fi

        if [ -d "$ARCHIVE_DIR" ]; then
            chmod 755 "$ARCHIVE_DIR"
            chmod 644 "$ARCHIVE_DIR"/*.pem
        fi

    done
}


# ============================================================
# Request certificate if it does not exist
# ============================================================

ensure_certificate() {

    HOST="$1"

    CERT_DIR="/etc/letsencrypt/live/$HOST"
    CERT_FILE="$CERT_DIR/fullchain.pem"

    echo "----------------------------------------"
    echo "Checking certificate for: $HOST"

    if [ -f "$CERT_FILE" ]; then
        echo "Certificate exists."
        return 0
    fi

    echo "Certificate does not exist."
    echo "Requesting certificate for: $HOST"

    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$CREDENTIALS" \
        --dns-cloudflare-propagation-seconds 30 \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        -d "$HOST"

    echo "Certificate created for: $HOST"
}


# ============================================================
# Check all certificates
# ============================================================

check_certificates() {

    echo "========================================"
    echo "Checking all configured certificates..."
    echo "========================================"

    for HOST in $HOSTS; do
        ensure_certificate "$HOST"
    done

    fix_certificate_permissions
}


# ============================================================
# Initial certificate check
# ============================================================

check_certificates


# ============================================================
# Renewal loop
# ============================================================

echo "========================================"
echo "Starting renewal loop..."
echo "========================================"

while true; do

    echo ""
    echo "========================================"
    echo "Checking certificates..."
    echo "========================================"

    check_certificates

    echo ""
    echo "Running certbot renew..."

    certbot renew \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$CREDENTIALS" \
        --dns-cloudflare-propagation-seconds 30

    echo ""
    echo "Fixing certificate permissions..."

    fix_certificate_permissions

    echo ""
    echo "Renewal check complete."
    echo "Sleeping for 12 hours..."

    sleep 12h

done

#!/bin/sh
set -eu

CERT="/etc/letsencrypt/live/mycoai.bandhuja.com/fullchain.pem"
MARKER="/etc/letsencrypt/.cert-renewed"

echo "Waiting for TLS certificate..."

while [ ! -f "$CERT" ]; do
    sleep 5
done

echo "TLS certificate found."

echo "Testing Nginx configuration..."
nginx -t

echo "Starting Nginx..."
nginx -g 'daemon off;' &
NGINX_PID=$!

last_marker_mtime=0

while true; do
    if [ -f "$MARKER" ]; then
        marker_mtime=$(stat -c %Y "$MARKER")

        if [ "$marker_mtime" -gt "$last_marker_mtime" ]; then
            echo "Certificate renewal detected."

            if nginx -t; then
                echo "Nginx configuration is valid. Reloading..."
                nginx -s reload
                last_marker_mtime="$marker_mtime"
            else
                echo "ERROR: Nginx configuration test failed."
                echo "Keeping current Nginx configuration."
            fi
        fi
    fi

    if ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "ERROR: Nginx process exited."
        exit 1
    fi

    sleep 30
done

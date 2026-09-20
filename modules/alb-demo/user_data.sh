#!/bin/bash
set -eux

dnf install -y nginx

# Config minima: /health devuelve 200 con el hostname para poder distinguir instancias.
cat > /etc/nginx/nginx.conf <<'NGINX'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    access_log /var/log/nginx/access.log;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 80 default_server;
        server_name _;

        location /health {
            add_header Content-Type text/plain;
            return 200 "OK\n";
        }

        location / {
            add_header Content-Type text/plain;
            return 200 "bedrock-incident-agent demo target\n";
        }
    }
}
NGINX

systemctl enable --now nginx

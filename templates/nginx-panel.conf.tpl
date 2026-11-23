# templates/nginx-panel.conf.tpl — public admin-panel listener (Phase 8).
# Installed at /etc/nginx/conf.d/panel.conf by setup-panel.sh (http context).
#
# Placeholders replaced by setup-panel.sh:
#   __PANEL_DOMAIN__       apex domain whose existing cert is reused
#   __PANEL_PORT__         listener port (default 8083)
#   __ADMIN_PATH__         URL prefix for the panel entry files
#   __PANEL_ROOT__         panel PHP root, outside every site docroot
#   __CERT_FULLCHAIN__     /etc/letsencrypt/live/<domain>/fullchain.pem
#   __CERT_PRIVKEY__       /etc/letsencrypt/live/<domain>/privkey.pem
#   __HTPASSWD_FILE__      bcrypt htpasswd file (root:root 0640)
#   __PHP_FPM_SOCKET__     PHP-FPM unix socket
#   __RATE_LIMIT_RATE__    limit_req rate, e.g. 10r/m
#   __PANEL_ACCESS_LOG__   panel access log
#   __PANEL_ERROR_LOG__    panel error log (also read by the fail2ban jail)

limit_req_zone $binary_remote_addr zone=wsa_panel:10m rate=__RATE_LIMIT_RATE__;

server {
    listen __PANEL_PORT__ ssl;
    server_name __PANEL_DOMAIN__;

    ssl_certificate     __CERT_FULLCHAIN__;
    ssl_certificate_key __CERT_PRIVKEY__;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:WSAPANEL:1m;
    ssl_session_timeout 10m;

    root  __PANEL_ROOT__;
    index index.php;

    access_log __PANEL_ACCESS_LOG__;
    error_log  __PANEL_ERROR_LOG__;

    auth_basic           "WSA Control Panel";
    auth_basic_user_file __HTPASSWD_FILE__;

    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    client_max_body_size 1m;

    # This listener answers one hostname only; silently drop the rest.
    if ($host != __PANEL_DOMAIN__) { return 444; }

    # Nothing except the admin path is reachable on this port.
    location / {
        deny all;
    }

    location ~ /\. {
        deny all;
    }

    location __ADMIN_PATH__/ {
        try_files $uri $uri/ =404;
    }

    location ~ ^__ADMIN_PATH__/.+\.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO       $fastcgi_path_info;
        fastcgi_pass  unix:__PHP_FPM_SOCKET__;
        # certbot renew --dry-run and WordPress downloads can exceed nginx's
        # default 60s FastCGI read timeout; the PHP action wrapper has a 600s cap.
        fastcgi_read_timeout 600;
        fastcgi_send_timeout 600;
        limit_req     zone=wsa_panel burst=10 nodelay;
    }
}

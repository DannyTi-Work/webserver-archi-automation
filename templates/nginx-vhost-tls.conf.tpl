server {
    listen 443 ssl;
    server_name __SERVER_NAMES__;

    root __DOCROOT__;
    index index.php index.html;

    access_log /var/log/nginx/__DOMAIN__.access.log;
    error_log  /var/log/nginx/__DOMAIN__.error.log;

    location / {
        try_files $uri $uri/ =404;
    }

    # Self-contained PHP handling (works with both Ubuntu and nginx.org layouts).
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_pass unix:__PHP_SOCKET__;
    }

    location ~ /\.ht {
        deny all;
    }

    # Same directives certbot's nginx installer writes, pointing at the
    # existing lineage. Renewals update these files; the deploy hook reloads
    # nginx, so no re-issuance is needed to (re)install a valid certificate.
    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    listen 80;
    server_name __SERVER_NAMES__;
    return 301 https://$host$request_uri;
}

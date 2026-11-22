server {
    listen 80;
    server_name __DOMAIN__;

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
}

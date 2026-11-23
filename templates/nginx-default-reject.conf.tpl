# Managed by scripts/setup.sh — do not edit on the VPS.
# Installed as /etc/nginx/conf.d/00-default-reject.conf.
#
# Without explicit default_server blocks, nginx falls back to the FIRST server
# block on each listener. On :443 that is another domain's TLS vhost, so an
# HTTPS request for a domain without a certificate gets served that site.
# These blocks make unmatched Hosts fail closed instead.
#
# IPv6: no [::] listeners exist on this stack; add matching default_server
# blocks here only if IPv6 is enabled later.

server {
    listen 80 default_server;
    server_name _;
    return 444;
}

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}

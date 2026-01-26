nginx -s reload -c /etc/nginx/nginx.conf
curl --unix-socket /var/run/docker.sock -X POST http://localhost/containers/xray/restart


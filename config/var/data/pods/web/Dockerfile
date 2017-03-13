FROM alpine:3.5
MAINTAINER "Max Goltzsche" <max.goltzsche@algorythm.de>

RUN addgroup nginx && adduser -S -D -G nginx nginx -H -s /sbin/nologin

RUN apk add --update --no-cache nginx certbot openssl

ADD nginx.conf /etc/nginx/
ADD proxy_params.conf /etc/nginx/
ADD ssl_params.conf /etc/nginx/
ADD default-vhost.conf /etc/nginx/conf.d/default.conf
ADD entrypoint.sh /

VOLUME /etc/ssl
VOLUME /etc/letsencrypt

EXPOSE 80 443

ENTRYPOINT ["/entrypoint.sh"]
#ENTRYPOINT ["/usr/sbin/nginx", "-g", "daemon off;"]

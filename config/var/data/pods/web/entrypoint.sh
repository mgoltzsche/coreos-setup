#!/bin/sh
#
# Generates nginx virtual host configuration based on consul's KV keys
# beginning with http/.
# Optionally starts a server that generates configuration invoked by incoming
# TCP connections.
# (The virtual host configuration cannot be provided by the client to
# prevent unauthorized configuration and avoid a more complex security concept)

usage() {
	echo "Usage: $0 [LISTENIP [LISTENPORT]]|reload" >&2
	exit 1
}

waitForConsulAgent() {
	for SEC in 1 1 3 3 5 10; do
		wget -qO - "http://consul:8500/v1/kv/?keys" >/dev/null 2>/dev/null && return 0
		sleep $SEC
	done
	echo "consul unavailable" >&2
	exit 1
}

waitForNginxProcess() {
	for SEC in 1 1 3 5; do
		[ -f /var/run/nginx.pid ] && ps -o pid | grep -wq "$(cat /var/run/nginx.pid)" && return 0
		sleep $1
	done
	echo "nginx unavailable" >&2
	exit 1
}

waitForNginxLoaded() {
	for SEC in 1 1 1 1 1; do
		nginx -s reload 2>/dev/null && return 0
		sleep 1
	done
	echo "nginx start timed out" >&2
	return 1
}

httpHosts() {
	echo "$HTTP_KEYS" | grep -Eo '"http/[a-z0-9_\-\.]+"' | sed -E -e 's/^"http\///' -e 's/"$//' | sort | uniq
}

configureNginxVirtualHosts() {
	ERROR=0
	waitForConsulAgent &&
	#find /etc/nginx/conf.d/ -name 'host-*.conf' -type f -exec rm {} \; && # Delete existing host configuration
	HTTP_KEYS="$(wget -qO - "http://consul:8500/v1/kv/http/?keys" 2>/dev/null || true)" &&
	HTTP_HOSTS="$(httpHosts)" &&
	CONSUL_IP="$(wget -qO - http://consul:8500/v1/catalog/service/consul 2>/dev/null | grep -Eo '"Address":"[^"]+"' | cut -d '"' -f 4)" &&
	mkdir -p $NGINX_WEB_ROOT &&
	# Remove outdated virtual hosts
	find /etc/nginx/conf.d/ -name 'host-*.conf' -type f | while read HOST_CONF_FILE; do
		if ! echo "$HTTP_HOSTS" | grep -xq "$(echo "$HOST_CONF_FILE" | sed -E 's/.*\/host-(.*)\.conf$/\1/g')"; then
			rm -f "$HOST_CONF_FILE" || return 1
		fi
	done
	# Configure virtual hosts
	if [ "$HTTP_HOSTS" ]; then
		echo "$HTTP_HOSTS" | while read HTTP_HOST; do
			VHOST_SSL_DIR="/etc/letsencrypt/live/$HTTP_HOST"
			[ -d "$VHOST_SSL_DIR" ] || (echo "Skipped virtual host $HTTP_HOST conf due to missing certificate" >&2; false) || continue;
			CONF_FILE="/etc/nginx/conf.d/host-$HTTP_HOST.conf"
			OLD_CONF="$(cat "$CONF_FILE" 2>/dev/null)"
			SERVICE_ADDRESS="$(wget -qO - "http://consul:8500/v1/kv/http/$HTTP_HOST?raw")" \
				|| (echo "Service address value for HTTP host '$HTTP_HOST' could not be resolved" >&2; false) || return 1
			([ "$SERVICE_ADDRESS" ] || (echo "Empty service address for HTTP host '$HTTP_HOST'" >&2; false)) &&
			SERVICE_ADDRESS="$(echo "$SERVICE_ADDRESS" | sed -E 's/([^:]+)(:[0-9]+)/\1.service.dc1.consul\2/')" &&
			# TODO: move service.dc1.consul into parameter
			cat > "$CONF_FILE" <<-EOF
				server {
				  listen      80;
				  listen [::]:80;
				  listen      443 ssl http2;
				  listen [::]:443 ssl http2;
				  server_name $HTTP_HOST;
				  access_log  stdout  main;
				  error_log   stderr  info;
				  root $NGINX_WEB_ROOT;

				  # SSL config
				  ssl_certificate $VHOST_SSL_DIR/fullchain.pem;
				  ssl_certificate_key $VHOST_SSL_DIR/privkey.pem;
				  include ssl_params.conf;

				  include proxy_params.conf;

				  # Proxy requests
				  location / {
					if (\$scheme = http) {
					  return 302 https://\$server_name\$request_uri;
					}
					resolver $CONSUL_IP valid=300s;
					resolver_timeout 5s;
					# Variable required to let nginx not resolve hostname at boot time
					set \$service http://$SERVICE_ADDRESS;
					proxy_pass \$service;
				  }

				  # Let's Encrypt verification endpoint
				  location ~ /.well-known {
					allow all;
				  }

				  error_page   500 503 504  /50x.html;
				  error_page   502          /502.html;
				  location = /50x.html {
					root $NGINX_WEB_ROOT;
				  }
				  location = /502.html {
					root $NGINX_WEB_ROOT;
				  }
				}
			EOF
			[ $? -eq 0 ] || return 1
			# Test config
			NGINX_CONF_TEST="$(nginx -t 2>&1)"
			if [ $? -eq 0 ]; then
				echo "Configured virtual host: $HTTP_HOST -> $SERVICE_ADDRESS"
			else
				# Revert invalid conf file
				echo "$NGINX_CONF_TEST" >&2;
				echo "Virtual host configuration failed: $HTTP_HOST -> $SERVICE_ADDRESS" >&2
				echo "Reverting invalid configuration file $CONF_FILE" >&2
				[ "$OLD_CONF" ] && echo "$OLD_CONF" > "$CONF_FILE" || rm "$CONF_FILE"
				ERROR=1 # TODO: make this the functions return code (currently not working due to while)
			fi
		done
	fi
	# Generate static HTML pages
	HOST_LIST_ENTRIES="$(echo "$HTTP_HOSTS" | sed -E 's/^.*$/<li><a href="https:\/\/\0">\0<\/a><\/li>/')"
	cat > $NGINX_WEB_ROOT/index.html <<-EOF
		<!DOCTYPE html>
		<html>
		<head>
		<title>Site not found!</title>
		<style>
			body {
				width: 35em;
				margin: 0 auto;
				font-family: Tahoma, Verdana, Arial, sans-serif;
			}
		</style>
		</head>
		<body>
			<h1>Welcome!</h1>
			<p>Sorry, the site you are looking for does not exist.</p>
			<h2>Available sites</h2>
			<ul>
				$HOST_LIST_ENTRIES
			</ul>
		</body>
		</html>
	EOF
	cat > $NGINX_WEB_ROOT/502.html <<-EOF
		<!DOCTYPE html>
		<html>
		<head>
		<title>Service unavailable</title>
		<style>
			body {
				width: 35em;
				margin: 0 auto;
				font-family: Tahoma, Verdana, Arial, sans-serif;
			}
		</style>
		</head>
		<body>
			<h1>Service unavailable</h1>
			<p>Sorry, this site is down for maintenance.</p>
			<h2>Available sites</h2>
			<ul>
				$HOST_LIST_ENTRIES
			</ul>
		</body>
		</html>
	EOF
	return $ERROR
}

generateDHGroup() {
	DH_FILE=/etc/ssl/certs/dhparam.pem
	mkdir -p "$(dirname "$DH_FILE")" || return 1
	if [ ! -f $DH_FILE ]; then
		echo 'Generating strong Diffie-Hellman group...' >&2
		openssl dhparam -out $DH_FILE 2048 || return 1
	fi
}

obtainSSLCertificates() {
	httpHosts | while read HTTP_HOST; do
		if [ ! -f "/etc/letsencrypt/live/$HTTP_HOST/fullchain.pem" ]; then
			echo "Obtaining new SSL certificate for $HTTP_HOST ..." >&2
			certbot certonly -q -a webroot --webroot-path=/var/lib/nginx/html --email "$ADMIN_EMAIL" --agree-tos -d "$HTTP_HOST" || return 1
		fi
	done
}

isTerminated() {
	! ps -o pid | grep -Exq "\s*$NGINX_PID" &&
	! ps -o pid | grep -Exq "\s*$RELOAD_SERVER_PID"
}

terminateGracefully() {
	# TODO: make work
	trap : 2 3 9 15
	kill -15 "$NGINX_PID" "$RELOAD_SERVER_PID" 2>/dev/null
	for SEC in 1 1 1 1 1 1 1; do
		isTerminated && exit ${1:-0}
		sleep 1
	done
	echo "Killing nginx since it did not respond" >&2
	kill -9 "$NGINX_PID" "$RELOAD_SERVER_PID"
	exit 1
}

NGINX_WEB_ROOT=/var/lib/nginx/html
[ "$ADMIN_EMAIL" ] || (echo "ADMIN_EMAIL env var not set!" >&2; false) || exit 1

if [ "$1" = reload ]; then # Reload nginx config
	[ $# -eq 1 ] || usage
	waitForNginxProcess &&
	# TODO: make sure this is not executed in parallel
	configureNginxVirtualHosts
	STATUS=$?
	nginx -s reload
	[ $? -eq 0 -a $STATUS -eq 0 ]
	exit $?
fi

# Start nginx & config reload service
RELOAD_SERVICE_IP="${RELOAD_SERVICE_IP:-0.0.0.0}"
RELOAD_SERVICE_PORT="${RELOAD_SERVICE_PORT:-9000}"
generateDHGroup &&
configureNginxVirtualHosts >/dev/null || exit 1 # 1st pass, skipping hosts with missing certificates
trap terminateGracefully 2 3 9 15
if [ $# -gt 0 ]; then
	$@ &
	NGINX_PID=$!
else
	nginx -g "daemon off;" &
	NGINX_PID=$!
fi
# TODO: renew certificates
waitForNginxLoaded &&
obtainSSLCertificates &&
configureNginxVirtualHosts || terminateGracefully 1 # 2nd pass with obtained certificates
nc -lk -s "$RELOAD_SERVICE_IP" -p "$RELOAD_SERVICE_PORT" -e "$0" reload &
RELOAD_SERVER_PID=$!
sleep 1
ps "$RELOAD_SERVER_PID" >/dev/null || terminateGracefully 1
while ! isTerminated; do
	wait
done

#!/bin/sh

[ "$1" ] || (echo "Usage: $0 SSHDESTINATION" >&2; false) &&
rsync -r --rsync-path="sudo rsync" --progress config/ "$1:/"
#tar -cjf - config | base64 | ssh "$1" -C 'rm -rf config && base64 -d | tar -xjf - && cd config &&
#	set -x &&
#	sudo mkdir -p /opt/bin /etc/rkt/net.d &&
#	sudo mv rkt/net.d/10-pod-net.conf /etc/rkt/net.d/ &&
#	for SCRIPT in $(ls scripts); do
#		sudo cp --force "scripts/$SCRIPT" "/opt/bin/$SCRIPT" &&
#		sudo chmod 755 "/opt/bin/$SCRIPT" || exit 1
#	done
#	for SERVICE in $(ls services); do
#		sudo cp --force "services/$SERVICE" "/etc/systemd/system/$SERVICE" &&
#		sudo chmod 644 "/etc/systemd/system/$SERVICE" &&
#		sudo systemctl enable "$SERVICE" || exit 1
#	done
#	sudo systemctl daemon-reload' 2>&1 | grep -Ev '^\+\+ |^\++ for'

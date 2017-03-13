#!/bin/sh

[ "$1" ] || (echo "Usage: $0 SSHDESTINATION" >&2; false) &&
rsync -r --rsync-path="sudo rsync" --progress config/ "$1:/"


install_docker2aci() {
	DOCKER2ACI_VERSION="v0.16.0"
	TMP_DIR=$(mktemp -d) &&
	wget -O $TMP_DIR/docker2aci.tar.gz "https://github.com/appc/docker2aci/releases/download/$DOCKER2ACI_VERSION/docker2aci-v0.16.0.tar.gz" &&
	tar xzf $TMP_DIR/docker2aci.tar.gz -C $TMP_DIR &&
	mv "$TMP_DIR/docker2aci-$DOCKER2ACI_VERSION/docker2aci" /opt/bin/docker2aci
	STATUS=$?
	rm -rf $TMP_DIR
	return $STATUS
}

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

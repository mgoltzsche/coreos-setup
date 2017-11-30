#!/bin/sh

SYSLOG_FORWARDING_ENABLED=${SYSLOG_FORWARDING_ENABLED:=false}
SYSLOG_HOST=${SYSLOG_HOST:=syslog}
SYSLOG_PORT=${SYSLOG_PORT:=514}
PG_ENCODING=${PG_ENCODING:=utf8}

# Runs the provided command until it succeeds.
# Takes the error message to be displayed if it doesn't succeed as first argument.
awaitSuccess() {
	MSG="$1"
	shift
	until $@ >/dev/null 2>/dev/null; do
		[ ! "$MSG" ] || echo "$MSG" >&2
		sleep 1
	done
}

# Tests if postgres has been started (before we can continue configuration)
isPostgresStarted() {
	ps -o pid | grep -Eq "^\s*$1\$" || exit 1
	gosu postgres psql -c 'SELECT 1'
}

# Configures postgres on first container start.
# Every container start it creates/updates users + dbs and runs init scripts.
setupPostgres() {
	FIRST_START=
	if [ ! -s "$PGDATA/PG_VERSION" ]; then
		# Create initial database directory
		FIRST_START='true'
		echo "Setting up initial database in $PGDATA"
		# --auth-host=md5 forces password authentication for TCP connections
		# (Startup warning to use these parameters can be ignored)
		gosu postgres initdb --auth-host=md5 $PG_INITDB_ARGS || exit 1
	fi

	# Start postgres locally for user and DB setup
	gosu postgres postgres -c listen_addresses=localhost &

	# Wait for postgres start
	awaitSuccess 'Waiting for local postgres to start before setup' isPostgresStarted $!
	echo 'Setting up users and DBs ...'

	# Check and set default postgres user password if undefined
	if [ ! "$PG_USER_POSTGRES" ]; then
		export PG_USER_POSTGRES=Secret123
		echo "WARNING: No postgres user password configured. Using '$PG_USER_POSTGRES'. Set PG_USER_POSTGRES to remove this warning" >&2
	fi

	for PG_USER_KEY in $(set | grep -Eo '^PG_USER_[^=]+' | sed 's/^PG_USER_//'); do
		PG_USER="$(echo -n "$PG_USER_KEY" | tr '[:upper:]' '[:lower:]')" # User name lower case
		PG_USER_PASSWORD="$(eval "echo \"\$PG_USER_$PG_USER_KEY\"")"
		PG_USER_DATABASE="$PG_USER"
		# Create user
		if ! gosu postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$PG_USER'" | grep -q 1; then
			echo "Adding PostgreSQL user: $PG_USER"
			gosu postgres createuser -E "$PG_USER" || exit 1
		else
			echo "Resetting PostgreSQL user's password: $PG_USER"
		fi
		# Reset user password
		gosu postgres psql -c "ALTER USER $PG_USER WITH ENCRYPTED PASSWORD '$PG_USER_PASSWORD'" >/dev/null || exit 1
		# Create user database
		if ! gosu postgres psql -lqt | cut -d \| -f 1 | grep -qw "$PG_USER_DATABASE"; then
			echo "Adding PostgreSQL database: $PG_USER_DATABASE"
			createDB "$PG_USER_DATABASE" "$PG_USER" || exit 1
		fi
	done

	# Run init scripts
	if [ "$FIRST_START" ]; then
		if [ "$(ls /entrypoint-initdb.d/)" ]; then
			echo "Running init scripts:"
			for f in /entrypoint-initdb.d/*; do
				case "$f" in
					*.sh)     echo "  Running $f"; . "$f" 2>&1 | sed 's/^/    /g' || exit 1 ;;
					*.sql)    echo "  Running $f"; gosu psql < "$f" 2>&1 | sed 's/^/    /g' || exit 1 ;;
					*.sql.gz) echo "  Running $f"; gunzip -c "$f" | gosu psql 2>&1 | sed 's/^/    /g' || exit 1 ;;
					*)        echo "  Ignoring $f" ;;
				esac
			done
		else
			echo 'No initscripts found in /entrypoint-initdb.d. Put *.sh, *.sql or *.sql.gz files there to initialize DB with on first start'
		fi
	fi

	terminatePid $(postgresPid)
}

createDB() {
	gosu postgres createdb -T template0 -O "$2" -E "$PG_ENCODING" "$1"
}

# Executes a backup task.
# (Maybe called locally or remotely by backup server)
backup() {
	if [ $# -eq 0 ]; then
		read CMD_RECEIVED
		read CMD_DATABASE
		read CMD_USERNAME
		read CMD_PASSWORD
	elif [ $# -eq 4 -o $# -eq 5 ]; then
		CMD_RECEIVED="$1"
		CMD_DATABASE="$2"
		CMD_USERNAME="$3"
		CMD_PASSWORD="$4"
	fi
	[ ! "$CMD_USERNAME" = postgres ] || (echo "postgres user not allowed in backup script" >&2; false) || return 1
	case "$CMD_RECEIVED" in
		dump-plain)
			echo "Dumping database $CMD_DATABASE" >&2
			# Dump via TCP to enforce authentication (configured with initdb --auth-host=md5)
			STATUS=0
			export PGPASSWORD="$CMD_PASSWORD"
			# maybe add -O
			pg_dump -h localhost -p 5432 -U "$CMD_USERNAME" -E $PG_ENCODING -n public -O \
				--inserts --blobs --no-tablespaces --no-owner --no-privileges \
				--disable-triggers --disable-dollar-quoting --serializable-deferrable \
				"$CMD_DATABASE" || STATUS=1
			unset PGPASSWORD
			return $STATUS
		;;
		restore-plain)
			STATUS=0
			export PGPASSWORD="$CMD_PASSWORD"
			(psql -h localhost -p 5432 -U "$CMD_USERNAME" "$CMD_DATABASE" -X -c 'SELECT 1' || (echo "Invalid credentials"; false)) &&
			echo "Restoring database $CMD_DATABASE" >&2 &&
			gosu postgres dropdb "$CMD_DATABASE" &&
			createDB "$CMD_DATABASE" "$CMD_USERNAME" || STATUS=1
			if [ $STATUS -eq 0 ]; then
				if [ $# -eq 5 ]; then
					CMD_FILE="$5"
					([ ! "$CMD_FILE" ] || [ ! -f "$CMD_FILE" ] || (echo "SQL restore file does not exist: $CMD_FILE" >&2; false)) &&
					cat "$CMD_FILE" | psql -h localhost -p 5432 -U "$CMD_USERNAME" "$CMD_DATABASE" -X -v ON_ERROR_STOP=1 || STATUS=1
				else
					psql -h localhost -p 5432 -U "$CMD_USERNAME" "$CMD_DATABASE" -X -v ON_ERROR_STOP=1 &&
					echo "Restored successfully" || STATUS=1
				fi
			fi
			unset PGPASSWORD
			return $STATUS
		;;
		*)
			echo "Unsupported command: $CMD_RECEIVED"
			echo "Usage: backup dump-plain DATABASE USERNAME PASSWORD" >&2
			return 1
		;;
	esac
}

# Starts a TCP server that performs db backup tasks for another container.
# Backup server required because pg_dump must be of same version as postgres
# which may not be available in most other containers (e.g. redmine).
# ATTENTION: Use backup server only in local net since it is unencrypted.
startBackupServer() {
	echo "Starting backup server on port 5433"
	nc -lk -s 0.0.0.0 -p 5433 -e /entrypoint.sh backup &
	BACKUP_SERVER_PID=$!
}

backupClient() {
	# TODO: check for line '-- PostgreSQL database dump complete'
	printf 'dump-plain\nredmine\nredmine\nredminesecret' | nc -w 3 localhost 5433
}

# Starts a local syslog server to collect and forward postgres logs.
startRsyslog() {
	echo "Starting rsyslogd ..."
	rm -f /var/run/rsyslogd.pid || exit 1
	SYSLOG_FORWARDING_CFG=
	if [ "$SYSLOG_FORWARDING_ENABLED" = 'true' ]; then
		awaitSuccess "Waiting for syslog UDP server $SYSLOG_HOST:$SYSLOG_PORT" nc -uzvw1 "$SYSLOG_HOST" "$SYSLOG_PORT"
		SYSLOG_FORWARDING_CFG="*.* @$SYSLOG_HOST:$SYSLOG_PORT"
	fi

	cat > /etc/rsyslog.conf <<-EOF
		\$ModLoad imuxsock.so # provides local unix socket under /dev/log
		\$ModLoad omstdout.so # provides messages to stdout
		\$template stdoutfmt,"%syslogtag% %msg%\n" # light stdout format

		*.* :omstdout:;stdoutfmt # send everything to stdout
		$SYSLOG_FORWARDING_CFG
	EOF
	[ $? -eq 0 ] &&
	chmod 444 /etc/rsyslog.conf || exit 1

	# Start rsyslog to collect logs
	rsyslogd -n -f /etc/rsyslog.conf &
	SYSLOG_PID=$!
	awaitSuccess 'Waiting for local rsyslog' [ -S /dev/log ]
}

# Provides postgres' current PID
postgresPid() {
	cat "$PGDATA/postmaster.pid" 2>/dev/null | head -1
}

# Tests if the provided PID is terminated
isProcessTerminated() {
	! ps -o pid | grep -wq ${1:-0}
}

# Waits until the provided PID is terminated
awaitTermination() {
	awaitSuccess '' isProcessTerminated $1
}

# Terminates the provided PID and waits until it is terminated
terminatePid() {
	kill $1 2>/dev/null
	awaitTermination $1
}

# Terminates the whole container orderly
terminateGracefully() {
	trap : SIGHUP SIGINT SIGQUIT SIGTERM # Unregister signal handler to avoid infinite recursion
	terminatePid $BACKUP_SERVER_PID
	terminatePid $(postgresPid)
	terminatePid $SYSLOG_PID
	exit 0
}

case "$1" in
	postgres)
		# Register signal handler for orderly shutdown
		trap terminateGracefully SIGHUP SIGINT SIGQUIT SIGTERM || exit 1
		startRsyslog
		setupPostgres
		isProcessTerminated "$(postgresPid)" || (echo 'Postgres is already running' >&2; false) || exit 1
		(
			gosu postgres $@
			terminateGracefully
		) &
		startBackupServer
		wait
	;;
	backup)
		$@ || exit $?
	;;
	*)
		exec "$@"
	;;
esac

all: build

build:
	docker build -t algorythm/postgres:latest --rm .

run:
	# Run container
	docker run -p 5432:5432 -h postgres.algorythm.de algorythm/postgres:latest

sh:
	# Start container with interactive shell
	docker run -it -h postgres.algorythm.de algorythm/postgres:latest /bin/sh

join:
	# Execute interactive shell on running container
	docker exec -it `docker ps | grep algorythm/postgres | cut -d ' ' -f 1` /bin/sh

kill:
	docker kill `docker ps | grep algorythm/postgres | cut -d ' ' -f 1`

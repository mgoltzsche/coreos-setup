FROM alpine:3.4
MAINTAINER "Max Goltzsche" <max.goltzsche@algorythm.de>

# Install rsyslog & postgres
RUN apk add --no-cache --update rsyslog postgresql

# Add gosu for easy step-down from root
# and tini for signal processing (graceful container termination) and zombie killing
# (Install all in one RUN block to keep image small without build utils)
ENV GOSU_VERSION 1.9
ENV TINI_VERSION v0.9.0
RUN set -x \
	&& apk add --no-cache --update curl gnupg \
	&& curl -fSL -o /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-amd64" \
	&& curl -fSL -o /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-amd64.asc" \
	&& export GNUPGHOME="$(mktemp -d)" \
	&& gpg --keyserver ha.pool.sks-keyservers.net --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 \
	&& gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu \
	&& rm -r "$GNUPGHOME" /usr/local/bin/gosu.asc \
	&& chmod +x /usr/local/bin/gosu \
	&& gosu nobody true \
	\
	&& curl -fSL -o /usr/local/bin/tini "https://github.com/krallin/tini/releases/download/$TINI_VERSION/tini-static" \
	&& curl -fSL -o /usr/local/bin/tini.asc "https://github.com/krallin/tini/releases/download/$TINI_VERSION/tini-static.asc" \
	&& export GNUPGHOME="$(mktemp -d)" \
	&& gpg --keyserver ha.pool.sks-keyservers.net --recv-keys 6380DC428747F6C393FEACA59A84159D7001A4E5 \
	&& gpg --batch --verify /usr/local/bin/tini.asc /usr/local/bin/tini \
	&& rm -r "$GNUPGHOME" /usr/local/bin/tini.asc \
	&& chmod +x /usr/local/bin/tini \
	&& tini -h >/dev/null \
	&& apk del --purge curl gnupg

# Modify default configuration
RUN sed -Ei "s/^#?(listen_addresses) ?=.*/\1 = '*'/" /usr/share/postgresql/postgresql.conf.sample \
	&& echo 'log_destination=syslog' >> /usr/share/postgresql/postgresql.conf.sample \
	&& echo "host all  all    0.0.0.0/0  md5" >> /usr/share/postgresql/pg_hba.conf.sample

EXPOSE 5432

ENV LANG en_US.utf8
ENV PGDATA /var/lib/postgresql/data
VOLUME  ["/etc/postgresql", "/var/log/postgresql", "/var/lib/postgresql"]

RUN mkdir /entrypoint-initdb.d
ADD entrypoint.sh /
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
#CMD ["postgres", "-D", "/var/lib/postgresql/data", "-c", "config_file=/var/lib/postgresql/data/postgresql.conf"]
CMD ["postgres"]
#CMD ["postgres", "--help"]

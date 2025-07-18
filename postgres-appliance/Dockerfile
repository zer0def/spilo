#ARG BASE_IMAGE=docker.io/library/ubuntu:22.04
ARG BASE_IMAGE=docker.io/library/debian:trixie-slim
ARG PGVERSION=15
ARG TIMESCALEDB="2.21.0"
ARG DEMO=false
ARG COMPRESS=false
ARG ADDITIONAL_LOCALES=


#FROM docker.io/library/ubuntu:18.04 as ubuntu-18
FROM docker.io/library/debian:trixie-slim as ubuntu-18

ARG ADDITIONAL_LOCALES

COPY build_scripts/locales.sh /builddeps/

RUN bash /builddeps/locales.sh


FROM $BASE_IMAGE as dependencies-builder

ARG DEMO

ENV WALG_VERSION=v3.0.7

COPY build_scripts/dependencies.sh /builddeps/

COPY dependencies/debs /builddeps/

RUN bash /builddeps/dependencies.sh


FROM $BASE_IMAGE as builder-false

ARG DEMO
ARG ADDITIONAL_LOCALES

COPY build_scripts/prepare.sh build_scripts/locales.sh /builddeps/

RUN bash /builddeps/prepare.sh

COPY --from=ubuntu-18 /usr/lib/locale/locale-archive /usr/lib/locale/locale-archive.18

COPY cron_unprivileged.c /builddeps/
COPY build_scripts/base.sh /builddeps/
COPY --from=dependencies-builder /builddeps/*.deb /builddeps/

ARG PGVERSION
ARG TIMESCALEDB
ARG TIMESCALEDB_APACHE_ONLY=false
ARG TIMESCALEDB_TOOLKIT=true
ARG COMPRESS
ARG PGOLDVERSIONS=""
ARG WITH_PERL=false

ARG DEB_PG_SUPPORTED_VERSIONS="$PGOLDVERSIONS $PGVERSION"

# Install PostgreSQL, extensions and contribs
ENV POSTGIS_VERSION=3.5 \
    BG_MON_COMMIT=7f5887218790b263fe3f42f85f4ddc9c8400b154 \
    PG_AUTH_MON_COMMIT=fe099eef7662cbc85b0b79191f47f52f1e96b779 \
    PG_MON_COMMIT=ead1de70794ed62ca1e34d4022f6165ff36e9a91 \
    SET_USER=REL4_1_0 \
    PLPROFILER=REL4_2_5 \
    PG_PROFILE=4.7 \
    PAM_OAUTH2=v1.0.1 \
    CITUS=v13.1.0 \
    PG_DUCKDB=v0.3.1 \
    PG_IVM=v1.9 \
    PARADEDB=v0.17.0 \
    VCHORD=0.4.3 \
    PG_PERMISSIONS_COMMIT=f4b7c18676fa64236a1c8e28d34a35764e4a70e2

WORKDIR /builddeps
RUN bash base.sh

# Install wal-g
COPY --from=dependencies-builder /builddeps/wal-g /usr/local/bin/

COPY build_scripts/patroni_wale.sh build_scripts/compress_build.sh /builddeps/

# Install patroni and wal-e
ENV PATRONIVERSION=4.0.6
ENV WALE_VERSION=1.1.1

WORKDIR /

RUN bash /builddeps/patroni_wale.sh

RUN if [ "$COMPRESS" = "true" ]; then bash /builddeps/compress_build.sh; fi


FROM scratch as builder-true
COPY --from=builder-false / /


FROM builder-${COMPRESS}

LABEL maintainer="Team ACID @ Zalando <team-acid@zalando.de>"

ARG PGVERSION
ARG TIMESCALEDB
ARG DEMO
ARG COMPRESS

EXPOSE 5432 8008 8080

ENV LC_ALL=en_US.utf-8 \
    PATH=$PATH:/usr/lib/postgresql/$PGVERSION/bin \
    PGHOME=/home/postgres \
    RW_DIR=/run \
    TIMESCALEDB=$TIMESCALEDB \
    DEMO=$DEMO

ENV WALE_ENV_DIR=$RW_DIR/etc/wal-e.d/env \
    LOG_ENV_DIR=$RW_DIR/etc/log.d/env \
    PGROOT=$PGHOME/pgdata/pgroot

ENV PGDATA=$PGROOT/data \
    PGLOG=$PGROOT/pg_log

ENV USE_OLD_LOCALES=false

WORKDIR $PGHOME

COPY motd /etc/
COPY runit /etc/service/
COPY pgq_ticker.ini $PGHOME/
COPY build_scripts/post_build.sh /builddeps/

RUN sh /builddeps/post_build.sh && rm -rf /builddeps/

COPY scripts bootstrap major_upgrade /scripts/
COPY launch.sh /

CMD ["/bin/sh", "/launch.sh", "init"]

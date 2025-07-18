#!/bin/bash

## -------------------------------------------
## Install PostgreSQL, extensions and contribs
## -------------------------------------------

export DEBIAN_FRONTEND=noninteractive
MAKEFLAGS="-j $(grep -c ^processor /proc/cpuinfo)"
export MAKEFLAGS

set -ex
#sed -i 's/^#\s*\(deb.*universe\)$/\1/g' /etc/apt/sources.list

apt-get update

BUILD_PACKAGES=(devscripts equivs build-essential fakeroot debhelper git gcc libc6-dev make cmake libevent-dev libbrotli-dev libssl-dev libkrb5-dev ninja-build clang)
if [ "$DEMO" = "true" ]; then
    export DEB_PG_SUPPORTED_VERSIONS="$PGVERSION"
    WITH_PERL=false
    rm -f ./*.deb
    apt-get install -y "${BUILD_PACKAGES[@]}"
else
    BUILD_PACKAGES+=(zlib1g-dev
                    libzstd-dev
                    libprotobuf-c-dev
                    libpam0g-dev
                    liblz4-dev
                    libcurl4-openssl-dev
                    libicu-dev
                    libc-ares-dev
                    pandoc
                    pkg-config)
    apt-get install -y "${BUILD_PACKAGES[@]}" libcurl4

    # install pam_oauth2.so
    git clone -b "$PAM_OAUTH2" --recurse-submodules https://github.com/zalando-pg/pam-oauth2.git
    make -C pam-oauth2 install

    # prepare 3rd sources
    git clone -b "$PLPROFILER" https://github.com/bigsql/plprofiler.git
    curl -sL "https://github.com/zalando-pg/pg_mon/archive/$PG_MON_COMMIT.tar.gz" | tar xz

    apt-get install -y python3-keyring python3-docutils ieee-data
fi

if [ "$WITH_PERL" != "true" ]; then
    apt-get install -y perl
fi

curl -sL "https://github.com/zalando-pg/bg_mon/archive/$BG_MON_COMMIT.tar.gz" | tar xz
curl -sL "https://github.com/zalando-pg/pg_auth_mon/archive/$PG_AUTH_MON_COMMIT.tar.gz" | tar xz
curl -sL "https://github.com/cybertec-postgresql/pg_permissions/archive/$PG_PERMISSIONS_COMMIT.tar.gz" | tar xz
curl -sL "https://github.com/zubkov-andrei/pg_profile/archive/$PG_PROFILE.tar.gz" | tar xz
git clone -b "$SET_USER" https://github.com/pgaudit/set_user.git
git clone https://github.com/timescale/timescaledb.git
git clone -b "${CITUS}" https://github.com/citusdata/citus.git
git clone -b "${PG_DUCKDB}" https://github.com/duckdb/pg_duckdb.git --recurse-submodules
git clone -b "${PG_IVM}" https://github.com/sraoss/pg_ivm.git
git clone -b "${PARADEDB}" https://github.com/paradedb/paradedb.git
git clone -b "${VCHORD}" https://github.com/tensorchord/vectorchord.git

apt-get install -y \
    postgresql-common \
    hunspell-en-us \
    libevent-2.1 \
    libevent-pthreads-2.1 \
    brotli \
    libbrotli1 \
    procps \
    python3.13 \
    python3-psycopg2

# forbid creation of a main cluster when package is installed
sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf

for version in $DEB_PG_SUPPORTED_VERSIONS; do
    sed -i "s/ main.*$/ main $version/g" /etc/apt/sources.list.d/pgdg.list
    apt-get update

    if [ "$DEMO" != "true" ]; then
        EXTRAS=("postgresql-pltcl-${version}"
                "postgresql-${version}-dirtyread"
                "postgresql-${version}-extra-window-functions"
                "postgresql-${version}-first-last-agg"
                "postgresql-${version}-hll"
                "postgresql-${version}-hypopg"
                "postgresql-${version}-mysql-fdw"
                "postgresql-${version}-partman"
                "postgresql-${version}-plproxy"
                "postgresql-${version}-pgaudit"
                "postgresql-${version}-pldebugger"
                "postgresql-${version}-pglogical"
                "postgresql-${version}-pglogical-ticker"
                "postgresql-${version}-plpgsql-check"
                "postgresql-${version}-pg-checksums"
                #"postgresql-${version}-pgdg-pgroonga"
                "postgresql-${version}-pgl-ddl-deploy"
                "postgresql-${version}-pgq-node"
                "postgresql-${version}-postgis-${POSTGIS_VERSION%.*}"
                "postgresql-${version}-postgis-${POSTGIS_VERSION%.*}-scripts"
                "postgresql-${version}-repack"
                "postgresql-${version}-wal2json"
                "postgresql-${version}-decoderbufs"
                "postgresql-${version}-pllua"
                "postgresql-${version}-pgvector")

        if [ "$WITH_PERL" = "true" ]; then
            EXTRAS+=("postgresql-plperl-${version}")
        fi
    fi

    # Install PostgreSQL binaries, contrib, plproxy and multiple pl's
    apt-get install --allow-downgrades -y \
        "postgresql-${version}-cron" \
        "postgresql-contrib-${version}" \
        "postgresql-${version}-pgextwlist" \
        "postgresql-plpython3-${version}" \
        "postgresql-server-dev-${version}" \
        "postgresql-${version}-pgq3" \
        "postgresql-${version}-pg-stat-kcache" \
        "${EXTRAS[@]}"

    # Install 3rd party stuff

    # use subshell to avoid having to cd back (SC2103)
    (
        cd timescaledb
        for v in $TIMESCALEDB; do
            git checkout "$v"
            sed -i "s/VERSION 3.11/VERSION 3.10/" CMakeLists.txt
            if BUILD_FORCE_REMOVE=true ./bootstrap -DREGRESS_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF \
                    -DTAP_CHECKS=OFF -DPG_CONFIG="/usr/lib/postgresql/$version/bin/pg_config" \
                    -DAPACHE_ONLY="$TIMESCALEDB_APACHE_ONLY" -DSEND_TELEMETRY_DEFAULT=NO; then
                make -C build install
                strip /usr/lib/postgresql/"$version"/lib/timescaledb*.so
            fi
            git reset --hard
            git clean -f -d
        done
    )

    (
      cd citus
      mkdir -p "build-${version}" && cd "build-${version}" && CFLAGS=-Werror ../configure PG_CONFIG=/usr/lib/postgresql/${version}/bin/pg_config --with-security-flags && make -j$(nproc) && make DESTDIR=/ install-all && make clean-full && cd ..
      git clean -fd
      cd ..
    )
    (
      cd pg_duckdb
      make PG_CONFIG=/usr/lib/postgresql/${version}/bin/pg_config -j$(nproc)
      make DESTDIR=/ install
      make clean-all
      git clean -fd
      cd ..
    )
    (  # pg_search/paradedb dependency
      cd pg_ivm
      make PG_CONFIG=/usr/lib/postgresql/${version}/bin/pg_config -j$(nproc)
      make DESTDIR=/ install
      git clean -fd
      cd ..
    )

    if [ "${TIMESCALEDB_APACHE_ONLY}" != "true" ] && [ "${TIMESCALEDB_TOOLKIT}" = "true" ]; then
        apt-get update
        if [ "$(apt-cache search --names-only "^timescaledb-toolkit-postgresql-${version}$" | wc -l)" -eq 1 ]; then
            apt-get install "timescaledb-toolkit-postgresql-$version"
        else
            echo "Skipping timescaledb-toolkit-postgresql-$version as it's not found in the repository"
        fi
    fi

    EXTRA_EXTENSIONS=()
    if [ "$DEMO" != "true" ]; then
        EXTRA_EXTENSIONS+=("plprofiler" "pg_mon-${PG_MON_COMMIT}")
    fi

    for n in bg_mon-${BG_MON_COMMIT} \
            pg_auth_mon-${PG_AUTH_MON_COMMIT} \
            set_user \
            pg_permissions-${PG_PERMISSIONS_COMMIT} \
            pg_profile-${PG_PROFILE} \
            "${EXTRA_EXTENSIONS[@]}"; do
        make -C "$n" USE_PGXS=1 clean install-strip
    done
done

# this is uh… not great
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --default-toolchain "${RUST_VERSION:-stable}" -y
_CARGO="${HOME}/.cargo/bin/cargo"
cd paradedb; CRATE=pgrx; PGRX_VERSION="$("${_CARGO}" tree --depth 1 -i "${CRATE}" -p pg_search | awk "/^${CRATE}/{print \$NF}")"; cd ..

"${_CARGO}" install --locked cargo-pgrx --version "${PGRX_VERSION#v}"
PGRX_INIT_ARGS=""
for version in $DEB_PG_SUPPORTED_VERSIONS; do
  PGRX_INIT_ARGS="${PGRX_INIT_ARGS} --pg${version}=/usr/lib/postgresql/${version}/bin/pg_config"
done
"${_CARGO}" pgrx init ${PGRX_INIT_ARGS}

(
cd paradedb/pg_search
for version in $DEB_PG_SUPPORTED_VERSIONS; do
  "${_CARGO}" pgrx package --features icu --pg-config "/usr/lib/postgresql/${version}/bin/pg_config"
  cp "../target/release/pg_search-pg${version}/usr/lib/postgresql/${version}/lib/"* "/usr/lib/postgresql/${version}/lib/"
  cp "../target/release/pg_search-pg${version}/usr/share/postgresql/${version}/extension/"* "/usr/share/postgresql/${version}/extension/"
done
cd ../..
)
(
cd vectorchord
for version in $DEB_PG_SUPPORTED_VERSIONS; do
  export PG_CONFIG="/usr/lib/postgresql/${version}/bin/pg_config"
  #make build
  PGRX_PG_CONFIG_PATH="${PG_CONFIG}" "${_CARGO}" run -p make -- build -o ./build/raw
  make install
  #tree build/raw
  unset PG_CONFIG
done
cd ..
)

rm -rf "${HOME}/.cargo" "${HOME}/.rustup"

apt-get install -y skytools3-ticker pgbouncer

sed -i "s/ main.*$/ main/g" /etc/apt/sources.list.d/pgdg.list
apt-get update
#apt-get install -y postgresql postgresql-server-dev-all postgresql-all libpq-dev
apt-get install -y libpq-dev
for version in $DEB_PG_SUPPORTED_VERSIONS; do
    apt-get install -y "postgresql-${version}" "postgresql-server-dev-${version}"
done

if [ "$DEMO" != "true" ]; then
    for version in $DEB_PG_SUPPORTED_VERSIONS; do
        # create postgis symlinks to make it possible to perform update
        ln -s "postgis-${POSTGIS_VERSION%.*}.so" "/usr/lib/postgresql/${version}/lib/postgis-2.5.so"
    done
fi

# make it possible for cron to work without root
gcc -s -shared -fPIC -o /usr/local/lib/cron_unprivileged.so cron_unprivileged.c

apt-get purge -y "${BUILD_PACKAGES[@]}"
apt-get autoremove -y

if [ "$WITH_PERL" != "true" ] || [ "$DEMO" != "true" ]; then
    dpkg -i ./*.deb || apt-get -y -f install
fi

# Remove unnecessary packages
:||apt-get purge -y \
                libdpkg-perl \
                libperl5.* \
                perl-modules-5.* \
                postgresql \
                postgresql-all \
                postgresql-server-dev-* \
                libpq-dev=* \
                libmagic1 \
                bsdmainutils
apt-get autoremove -y
apt-get clean
dpkg -l | grep '^rc' | awk '{print $2}' | xargs apt-get purge -y

# Try to minimize size by creating symlinks instead of duplicate files
if [ "$DEMO" != "true" ]; then
    cd "/usr/lib/postgresql/$PGVERSION/bin"
    for u in clusterdb \
            pg_archivecleanup \
            pg_basebackup \
            pg_isready \
            pg_recvlogical \
            pg_test_fsync \
            pg_test_timing \
            pgbench \
            reindexdb \
            vacuumlo *.py; do
        for v in /usr/lib/postgresql/*; do
            if [ "$v" != "/usr/lib/postgresql/$PGVERSION" ] && [ -f "$v/bin/$u" ]; then
                rm "$v/bin/$u"
                ln -s "../../$PGVERSION/bin/$u" "$v/bin/$u"
            fi
        done
    done

    set +x

    for v1 in $(find /usr/share/postgresql -type d -mindepth 1 -maxdepth 1 | sort -Vr); do
        # relink files with the same content
        cd "$v1/extension"
        while IFS= read -r -d '' orig
        do
            for f in "${orig%.sql}"--*.sql; do
                if [ ! -L "$f" ] && diff "$orig" "$f" > /dev/null; then
                    echo "creating symlink $f -> $orig"
                    rm "$f" && ln -s "$orig" "$f"
                fi
            done
        done <  <(find . -type f -maxdepth 1 -name '*.sql' -not -name '*--*')

        for e in pgq pgq_node plproxy address_standardizer address_standardizer_data_us; do
            orig=$(basename "$(find . -maxdepth 1 -type f -name "$e--*--*.sql" | head -n1)")
            if [ "x$orig" != "x" ]; then
                for f in "$e"--*--*.sql; do
                    if [ "$f" != "$orig" ] && [ ! -L "$f" ] && diff "$f" "$orig" > /dev/null; then
                        echo "creating symlink $f -> $orig"
                        rm "$f" && ln -s "$orig" "$f"
                    fi
                done
            fi
        done
        cd $v1/tsearch_data && ln -s english.stop zulip_english.stop

        # relink files with the same name and content across different major versions
        started=0
        for v2 in $(find /usr/share/postgresql -type d -mindepth 1 -maxdepth 1 | sort -Vr); do
            if [ "$v1" = "$v2" ]; then
                started=1
            elif [ $started = 1 ]; then
                for d1 in extension contrib contrib/postgis-$POSTGIS_VERSION; do
                    cd "$v1/$d1"
                    d2="$d1"
                    d1="../../${v1##*/}/$d1"
                    if [ "${d2%-*}" = "contrib/postgis" ]; then
                        d1="../$d1"
                    fi
                    d2="$v2/$d2"
                    for f in *.html *.sql *.control *.pl; do
                        if [ -f "$d2/$f" ] && [ ! -L "$d2/$f" ] && diff "$d2/$f" "$f" > /dev/null; then
                            echo "creating symlink $d2/$f -> $d1/$f"
                            rm "$d2/$f" && ln -s "$d1/$f" "$d2/$f"
                        fi
                    done
                done
            fi
        done
    done
    set -x
fi

# Clean up
rm -rf /var/lib/apt/lists/* \
        /var/cache/debconf/* \
        /builddeps \
        /usr/share/doc \
        /usr/share/man \
        /usr/share/info \
        /usr/share/locale/?? \
        /usr/share/locale/??_?? \
        /usr/share/postgresql/*/man \
        /etc/pgbouncer/* \
        /usr/lib/postgresql/*/bin/createdb \
        /usr/lib/postgresql/*/bin/createlang \
        /usr/lib/postgresql/*/bin/createuser \
        /usr/lib/postgresql/*/bin/dropdb \
        /usr/lib/postgresql/*/bin/droplang \
        /usr/lib/postgresql/*/bin/dropuser \
        /usr/lib/postgresql/*/bin/pg_standby \
        /usr/lib/postgresql/*/bin/pltcl_*
find /var/log -type f -print0 | xargs -0r -- truncate --size 0

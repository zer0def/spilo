#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

sed -i 's/65534/998/g' /etc/passwd /etc/group  # nobody
echo -e 'APT::Install-Recommends "0";\nAPT::Install-Suggests "0";' > /etc/apt/apt.conf.d/01norecommend

groupadd -r -g 999 postgres
useradd -r -u 999 -g 999 postgres
apt-get update
apt-get -y upgrade
apt-get install -y curl ca-certificates less locales jq vim-tiny gnupg cron runit dumb-init libcap2-bin rsync sysstat gpg software-properties-common

ln -s chpst /usr/bin/envdir

# Make it possible to use the following utilities without root (if container runs without "no-new-privileges:true")
setcap 'cap_sys_nice+ep' /usr/bin/chrt
setcap 'cap_sys_nice+ep' /usr/bin/renice

# Disable unwanted cron jobs
rm -fr /etc/cron.??*
truncate --size 0 /etc/crontab

if [ "$DEMO" != "true" ]; then
    # Required for wal-e
    apt-get install -y pv lzop
    # install etcdctl
    ETCDVERSION=3.3.27
    curl -L https://github.com/coreos/etcd/releases/download/v${ETCDVERSION}/etcd-v${ETCDVERSION}-linux-"$(dpkg --print-architecture)".tar.gz \
                | tar xz -C /bin --strip=1 --wildcards --no-anchored --no-same-owner etcdctl etcd
fi

# Dirty hack for smooth migration of existing dbs
bash /builddeps/locales.sh
mv /usr/lib/locale/locale-archive /usr/lib/locale/locale-archive.22
ln -s /run/locale-archive /usr/lib/locale/locale-archive
ln -s /usr/lib/locale/locale-archive.22 /run/locale-archive

# Add PGDG repositories
DISTRIB_CODENAME=$(sed -n 's/DISTRIB_CODENAME=//p' /etc/lsb-release)
for t in deb deb-src; do
    echo "$t http://apt.postgresql.org/pub/repos/apt/ ${DISTRIB_CODENAME}-pgdg main" >> /etc/apt/sources.list.d/pgdg.list
done
curl -s -o - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/apt.postgresql.org.gpg

# add TimescaleDB repository
echo "deb [signed-by=/etc/apt/keyrings/timescale_timescaledb-archive-keyring.gpg] https://packagecloud.io/timescale/timescaledb/ubuntu/ ${DISTRIB_CODENAME} main" | tee /etc/apt/sources.list.d/timescaledb.list
curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor | tee /etc/apt/keyrings/timescale_timescaledb-archive-keyring.gpg > /dev/null

# Add Groonga and pgGroonga repoistories
add-apt-repository ppa:groonga/ppa
curl -s -o - https://packages.groonga.org/ubuntu/groonga-keyring.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/packages.groonga.org.gpg
echo "deb https://packages.groonga.org/ubuntu/ ${DISTRIB_CODENAME} universe" > /etc/apt/sources.list.d/pgroonga.list

# Add Citus repositories
#curl -sL -o- https://packagecloud.io/citusdata/community/gpgkey | gpg --dearmor > /etc/apt/trusted.gpg.d/repos.citusdata.com.gpg
#curl -sL -o- https://repos.citusdata.com/community/gpgkey | gpg --dearmor > /etc/apt/trusted.gpg.d/repos.citusdata.com.gpg
#echo "deb https://packagecloud.io/citusdata/community/ubuntu/ ${DISTRIB_CODENAME} main" > /etc/apt/sources.list.d/citus.list
#echo "deb https://repos.citusdata.com/community/ubuntu/ ${DISTRIB_CODENAME} main" > /etc/apt/sources.list.d/citus.list

# Clean up
apt-get purge -y libcap2-bin
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* \
            /var/cache/debconf/* \
            /usr/share/doc \
            /usr/share/man \
            /usr/share/locale/?? \
            /usr/share/locale/??_??
find /var/log -type f -print0 | xargs -0r -- truncate --size 0

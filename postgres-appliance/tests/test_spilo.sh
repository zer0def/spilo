#!/bin/bash

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# shellcheck disable=SC1091
source ./test_utils.sh

readonly PREFIX="demo-"
readonly UPGRADE_SCRIPT="python3 /scripts/inplace_upgrade.py"
readonly TIMEOUT=120


function cleanup() {
    stop_containers
    docker ps -q --filter="ancestor=${SPILO_TEST_IMAGE:-spilo}" --filter="name=${PREFIX}" | xargs docker rm -f
}

function get_non_leader() {
    declare -r container=$1

    if [[ "$container" == "${PREFIX}spilo1" ]]; then
        echo "${PREFIX}spilo2"
    else
        echo "${PREFIX}spilo1"
    fi
}

function find_leader() {
    local container=$1
    local silent=$2
    declare -r timeout=$TIMEOUT
    local attempts=0

    while true; do
        leader=$(docker_exec "$container" 'patronictl list -f tsv' 2> /dev/null | awk '($4 == "Leader"){print $2}')
        if [[ -n "$leader" ]]; then
            [ -z "$silent" ] && echo "$leader"
            return
        fi
        ((attempts++))
        if [[ $attempts -ge $timeout ]]; then
            docker logs "$container"
            log_error "Leader is not running after $timeout seconds"
        fi
        sleep 1
    done
}

function wait_backup() {
    local container=$1

    declare -r timeout=$TIMEOUT
    local attempts=0

    # speed up backup creation
    local backup_starter_pid
    backup_starter_pid=$(docker exec "$container" pgrep -f '/bin/bash /scripts/patroni_wait.sh -t 3600 -- envdir /run/etc/wal-e.d/env /scripts/postgres_backup.sh')
    if [ -n "$backup_starter_pid" ]; then
        docker exec "$container" pkill -P "$backup_starter_pid" -f 'sleep 60'
    fi

    log_info "Waiting for backup on S3..,"

    sleep 1

    docker_exec -i "$1" "psql -U postgres -c CHECKPOINT" > /dev/null 2>&1

    while true; do
        count=$(docker_exec "$container" "envdir /run/etc/wal-e.d/env wal-g backup-list" | grep -c ^base)
        if [[ "$count" -gt 0 ]]; then
            return
        fi
        ((attempts++))
        if [[ $attempts -ge $timeout ]]; then
            log_error "No backup produced after $timeout seconds"
        fi
        sleep 1
    done
}

function wait_query() {
    local container=$1
    local query=$2
    local result=$3

    declare -r timeout=$TIMEOUT
    local attempts=0

    while true; do
        ret=$(docker_exec "$container" "psql -U postgres -tAc \"$query\"")
        if [[ "$ret" = "$result" ]]; then
            return 0
        fi
        ((attempts++))
        if [[ $attempts -ge $timeout ]]; then
            log_error "Query \"$query\" didn't return expected result $result after $timeout seconds"
        fi
        sleep 1
    done
}

function wait_all_streaming() {
    local repl_count=${2:-2}
    log_info "Waiting for all replicas to start streaming from the leader ($1)..."
    wait_query "$1" "SELECT COUNT(*) FROM pg_stat_replication WHERE application_name LIKE 'spilo_'" "$repl_count"
}

function wait_zero_lag() {
    local repl_count=${2:-2}
    log_info "Waiting for all replicas to catch up with WAL replay..."
    wait_query "$1" "SELECT COUNT(*) FROM pg_stat_replication WHERE application_name LIKE 'spilo_' AND pg_catalog.pg_wal_lsn_diff(pg_catalog.pg_current_wal_lsn(), COALESCE(replay_lsn, '0/0')) < 16*1024*1024" "$repl_count"
}

function create_schema() {
    docker_exec -i "$1" "psql -U postgres" < schema.sql
}

function create_timescaledb() {
    docker_exec -i "$1" "psql -U postgres" < timescaledb.sql
}

function drop_timescaledb() {
    docker_exec "$1" "psql -U postgres -d test_db -c 'DROP EXTENSION timescaledb CASCADE'"
}

function test_inplace_upgrade_wrong_version() {
    docker_exec "$1" "PGVERSION=13 $UPGRADE_SCRIPT 3" 2>&1 | grep 'Upgrade is not required'
}

function test_inplace_upgrade_wrong_capacity() {
    docker_exec "$1" "PGVERSION=14 $UPGRADE_SCRIPT 4" 2>&1 | grep 'number of replicas does not match'
}

function test_successful_inplace_upgrade_to_14() {
    docker_exec "$1" "PGVERSION=14 $UPGRADE_SCRIPT 3"
}

function test_envdir_suffix() {
    docker_exec "$1" "cat /run/etc/wal-e.d/env/WALG_S3_PREFIX" | grep -q "$2$" \
        && docker_exec "$1" "cat /run/etc/wal-e.d/env/WALE_S3_PREFIX" | grep -q "$2$"
}

function test_envdir_updated_to_x() {
    for c in {1..3}; do
        test_envdir_suffix "${PREFIX}spilo$c" "$1" || return 1
    done
}

function test_failed_inplace_upgrade_big_replication_lag() {
    ! test_successful_inplace_upgrade_to_14 "$1"
}

function test_successful_inplace_upgrade_to_15() {
    docker_exec "$1" "PGVERSION=15 $UPGRADE_SCRIPT 3"
}

function test_successful_inplace_upgrade_to_16() {
    docker_exec "$1" "PGVERSION=16 $UPGRADE_SCRIPT 3"
}

function test_successful_inplace_upgrade_to_17() {
    docker_exec "$1" "PGVERSION=17 $UPGRADE_SCRIPT 3"
}

function test_pg_upgrade_to_17_check_failed() {
    ! test_successful_inplace_upgrade_to_17 "$1"
}

function start_clone_with_wale_upgrade_container() {
    local ID=${1:-1}

    docker-compose run \
        -e SCOPE=upgrade \
        -e PGVERSION=14 \
        -e CLONE_SCOPE=demo \
        -e CLONE_METHOD=CLONE_WITH_WALE \
        -e CLONE_TARGET_TIME="$(next_minute)" \
        -e WALE_BACKUP_THRESHOLD_PERCENTAGE=80 \
        --name "${PREFIX}upgrade$ID" \
        -d "spilo$ID"
}

function start_clone_with_wale_upgrade_replica_container() {
    start_clone_with_wale_upgrade_container 2
}

function start_clone_with_wale_upgrade_to_17_container() {
    docker-compose run \
        -e SCOPE=upgrade3 \
        -e PGVERSION=17 \
        -e CLONE_SCOPE=demo \
        -e CLONE_PGVERSION=13 \
        -e CLONE_METHOD=CLONE_WITH_WALE \
        -e CLONE_TARGET_TIME="$(next_minute)" \
        --name "${PREFIX}upgrade4" \
        -d "spilo3"
}

function start_clone_with_wale_17_container() {
    docker-compose run \
        -e SCOPE=clone16 \
        -e PGVERSION=17 \
        -e CLONE_SCOPE=upgrade3 \
        -e CLONE_PGVERSION=17 \
        -e CLONE_METHOD=CLONE_WITH_WALE \
        -e CLONE_TARGET_TIME="$(next_hour)" \
        --name "${PREFIX}clone16" \
        -d "spilo3"
}

function start_clone_with_basebackup_upgrade_container() {
    local container=$1
    docker-compose run \
        -e SCOPE=upgrade2 \
        -e PGVERSION=15 \
        -e CLONE_SCOPE=upgrade \
        -e CLONE_METHOD=CLONE_WITH_BASEBACKUP \
        -e CLONE_HOST="$(docker_exec "$container" "hostname --ip-address")" \
        -e CLONE_PORT=5432 \
        -e CLONE_USER=standby \
        -e CLONE_PASSWORD=standby \
        --name "${PREFIX}upgrade3" \
        -d spilo3
}

function start_clone_with_hourly_log_rotation() {
    docker-compose run \
        -e SCOPE=hourlylogs \
        -e PGVERSION=17 \
        -e LOG_SHIP_HOURLY="true" \
        -e CLONE_SCOPE=upgrade2 \
        -e CLONE_PGVERSION=15 \
        -e CLONE_METHOD=CLONE_WITH_WALE \
        -e CLONE_TARGET_TIME="$(next_minute)" \
        --name "${PREFIX}hourlylogs" \
        -d "spilo3"
}

function verify_clone_upgrade() {
    local type=$2
    local from_version=$3
    local to_version=$4
    log_info "Waiting for clone with $type and upgrade $from_version->$to_version to complete..."
    find_leader "$1" 1
    wait_query "$1" "SELECT current_setting('server_version_num')::int/10000" "$to_version" 2> /dev/null
}

function verify_archive_mode_is_on() {
    archive_mode=$(docker_exec "$1" "psql -U postgres -tAc \"SHOW archive_mode\"")
    [ "$archive_mode" = "on" ]
}

function verify_hourly_log_rotation() {
    log_rotation_age=$(docker_exec "$1" "psql -U postgres -tAc \"SHOW log_rotation_age\"")
    log_filename=$(docker_exec "$1" "psql -U postgres -tAc \"SHOW log_filename\"")
    # we expect 8x24 foreign tables and views + 8 views for daily logs and failed authentications
    postgres_log_ftables=$(docker_exec "$1" "psql -U postgres -tAc \"SELECT count(*) FROM pg_foreign_table WHERE ftrelid::regclass::text LIKE 'postgres_log_%'\"")
    postgres_log_views=$(docker_exec "$1" "psql -U postgres -tAc \"SELECT count(*) FROM pg_views WHERE viewname LIKE 'postgres_log_%'\"")
    postgres_failed_auth_views=$(docker_exec "$1" "psql -U postgres -tAc \"SELECT count(*) FROM pg_views WHERE viewname LIKE 'failed_authentication_%'\"")

    [ "$log_rotation_age" = "1h" ] && [ "$log_filename" = "postgresql-%u-%H.log" ] && [ "$postgres_log_ftables" -eq 192 ] && [ "$postgres_log_views" -eq 8 ] && [ "$postgres_failed_auth_views" -eq 200 ]
}

# TEST SUITE 1 - In-place major upgrade 13->14->...->17
# TEST SUITE 2 - Major upgrade 13->17 after wal-e clone (with CLONE_PGVERSION set)
# TEST SUITE 3 - PITR (clone with wal-e) with unreachable target (14+)
# TEST SUITE 4 - Major upgrade 13->14 after wal-e clone (no CLONE_PGVERSION)
# TEST SUITE 5 - Replica bootstrap with wal-e
# TEST SUITE 6 - Major upgrade 14->15 after clone with basebackup
# TEST SUITE 7 - Hourly log rotation
function test_spilo() {
    # TEST SUITE 1
    local container=$1

    run_test test_envdir_suffix "$container" 13

    log_info "[TS1] Testing wrong upgrade setups"
    run_test test_inplace_upgrade_wrong_version "$container"
    run_test test_inplace_upgrade_wrong_capacity "$container"

    wait_all_streaming "$container"
    create_schema "$container" || exit 1 # incompatible upgrade exts, custom tbl with statistics and data
    # run_test test_failed_inplace_upgrade_big_replication_lag "$container"

    wait_zero_lag "$container"
    run_test verify_archive_mode_is_on "$container"
    wait_backup "$container"


    # TEST SUITE 2
    local upgrade3_container
    upgrade3_container=$(start_clone_with_wale_upgrade_to_17_container) # SCOPE=upgrade3 PGVERSION=17 CLONE: _SCOPE=demo _PGVERSION=13 _TARGET_TIME=<next_min>
    log_info "[TS2] Started $upgrade3_container for testing major upgrade 13->17 after clone with wal-e"


    # TEST SUITE 4
    local upgrade_container
    upgrade_container=$(start_clone_with_wale_upgrade_container) # SCOPE=upgrade PGVERSION=14 CLONE: _SCOPE=demo _TARGET_TIME=<next_min>
    log_info "[TS4] Started $upgrade_container for testing major upgrade 13->14 after clone with wal-e"


    # TEST SUITE 1
    # wait clone to finish and prevent timescale installation gets cloned
    find_leader "$upgrade3_container"
    find_leader "$upgrade_container"
    create_timescaledb "$container" # we don't install it at the beginning, as we do 13->17 in a clone

    log_info "[TS1] Testing in-place major upgrade 13->14"
    wait_zero_lag "$container"
    run_test test_successful_inplace_upgrade_to_14 "$container"
    wait_all_streaming "$container"
    run_test test_envdir_updated_to_x 14

    # TEST SUITE 2
    log_info "[TS2] Testing in-place major upgrade 13->17 after wal-e clone"
    run_test verify_clone_upgrade "$upgrade3_container" "wal-e" 13 17

    run_test verify_archive_mode_is_on "$upgrade3_container"
    wait_backup "$upgrade3_container"


    # TEST SUITE 3
    local clone17_container
    clone17_container=$(start_clone_with_wale_17_container) # SCOPE=clone17 CLONE: _SCOPE=upgrade3 _PGVERSION=17 _TARGET_TIME=<next_hour>
    log_info "[TS3] Started $clone17_container for testing point-in-time recovery (clone with wal-e) with unreachable target on 14+"


    # TEST SUITE 1
    log_info "[TS1] Testing in-place major upgrade 14->15"
    run_test test_successful_inplace_upgrade_to_15 "$container"
    wait_all_streaming "$container"
    run_test test_envdir_updated_to_x 15


    # TEST SUITE 3
    find_leader "$clone17_container"
    run_test verify_archive_mode_is_on "$clone17_container"


    # TEST SUITE 1
    wait_backup "$container"

    log_info "[TS1] Testing in-place major upgrade to 15->16"
    run_test test_successful_inplace_upgrade_to_16 "$container"
    wait_all_streaming "$container"
    run_test test_envdir_updated_to_x 16


    # TEST SUITE 4
    log_info "[TS4] Testing in-place major upgrade 13->14 after clone with wal-e"
    run_test verify_clone_upgrade "$upgrade_container" "wal-e" 13 14

    run_test verify_archive_mode_is_on "$upgrade_container"
    wait_backup "$upgrade_container"


    # TEST SUITE 5
    local upgrade_replica_container
    upgrade_replica_container=$(start_clone_with_wale_upgrade_replica_container)  # SCOPE=upgrade
    log_info "[TS5] Started $upgrade_replica_container for testing replica bootstrap with wal-e"


    # TEST SUITE 6
    local basebackup_container
    basebackup_container=$(start_clone_with_basebackup_upgrade_container "$upgrade_container")  # SCOPE=upgrade2 PGVERSION=15 CLONE: _SCOPE=upgrade
    log_info "[TS6] Started $basebackup_container for testing major upgrade 14->15 after clone with basebackup"
    wait_backup "$basebackup_container"

    # TEST SUITE 1
    # run_test test_pg_upgrade_to_17_check_failed "$container"  # pg_upgrade --check complains about timescaledb

    wait_backup "$container"

    # drop_timescaledb "$container"
    log_info "[TS1] Testing in-place major upgrade 16->17"
    run_test test_successful_inplace_upgrade_to_17 "$container"
    wait_all_streaming "$container"
    run_test test_envdir_updated_to_x 17


    # TEST SUITE 5
    log_info "[TS5] Waiting for postgres to start in the $upgrade_replica_container and stream from primary..."
    wait_all_streaming "$upgrade_container" 1

    # TEST SUITE 7
    local hourlylogs_container
    hourlylogs_container=$(start_clone_with_hourly_log_rotation "$upgrade_container")
    log_info "[TS7] Started $hourlylogs_container for testing hourly log rotation"

    # TEST SUITE 6
    log_info "[TS6] Testing in-place major upgrade 14->15 after clone with basebackup"
    run_test verify_clone_upgrade "$basebackup_container" "basebackup" 14 15
    run_test verify_archive_mode_is_on "$basebackup_container"

    # TEST SUITE 7
    find_leader "$hourlylogs_container"
    log_info "[TS7] Testing correct setup with hourly log rotation"
    run_test verify_hourly_log_rotation "$hourlylogs_container"
}

function main() {
    cleanup
    start_containers

    log_info "Waiting for leader..."
    local leader
    leader="$PREFIX$(find_leader "${PREFIX}spilo1")"
    test_spilo "$leader"
}

trap cleanup QUIT TERM EXIT

main

#!/usr/bin/env bash
# Sourced by the Fedora 44 image orchestrator.
build_pid_start() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }

build_write_status() {
    local tmp
    tmp=$(mktemp "$output/.status.XXXXXXXX")
    jq -n --arg state "$build_state" --arg stage "$build_stage" \
        --arg run "$UKE_BUILD_RUN_ID" --argjson completed "$build_completed" \
        --argjson total "$build_total" --argjson started "$build_started" \
        --argjson updated "$(date +%s)" \
        '{schema_version:1,run_id:$run,state:$state,stage:$stage,
          completed:$completed,total:$total,started_unix:$started,updated_unix:$updated}' > "$tmp"
    chmod 0666 "$tmp"
    mv -f -- "$tmp" "$output/status.json"
}

build_progress() {
    UKE_BUILD_OUTPUT=$output bash "${BASH_SOURCE[0]}" stage "$1"
}

build_progress_done() {
    UKE_BUILD_OUTPUT=$output bash "${BASH_SOURCE[0]}" done
}

build_containers() {
    "$container" ps -q --filter "label=org.uke-fedora.build-run=$UKE_BUILD_RUN_ID"
}

build_stop_containers() {
    local ids
    mapfile -t ids < <(build_containers)
    ((${#ids[@]} == 0)) || "$container" stop --time 10 "${ids[@]}" >/dev/null 2>&1 || true
    mapfile -t ids < <(build_containers)
    ((${#ids[@]} == 0)) || "$container" kill "${ids[@]}" >/dev/null 2>&1 || true
}

build_finish() {
    local code=$1
    trap - EXIT INT TERM
    build_completed=$(jq -r .completed "$output/status.json")
    build_stage=$(jq -r .stage "$output/status.json")
    if ((code == 0 && build_completed == build_total)); then
        build_state=complete
        build_stage='All image pairs complete'
    elif ((code == 0)); then
        build_state=failed
        build_stage='Build ended before all stages completed'
    elif [[ -e $output/.cancel-requested || $code == 130 || $code == 143 ]]; then
        build_state=cancelled
        build_stage='Stopped by user'
    else
        build_state=failed
    fi
    if [[ $build_state != complete ]]; then build_stop_containers; fi
    build_write_status
    printf '%s: %s (%s/%s stages)\n' "$build_state" "$build_stage" \
        "$build_completed" "$build_total" | tee -a "$output/progress.log"
    rm -f -- "$output/.build-run" "$output/.cancel-requested"
    if [[ -n ${stock_dir:-} ]]; then rm -rf -- "$stock_dir"; fi
    if ((code == 0)) && [[ $build_state == failed ]]; then exit 1; fi
}

build_start() {
    local old_pid old_start old_id old_container self_pid
    exec 9>"$output/.build.lock"
    flock -n 9 || { echo "Build already active in $output" >&2; return 1; }
    if [[ -f $output/.build-run ]]; then
        IFS=$'\t' read -r old_pid old_start old_id old_container < "$output/.build-run"
        [[ $old_container == docker || $old_container == podman ]] || {
            echo 'Invalid previous build identity' >&2; return 1;
        }
        if [[ $(build_pid_start "$old_pid") == "$old_start" ]] || \
           [[ -n $old_id && -n $("$old_container" ps -q --filter "label=org.uke-fedora.build-run=$old_id") ]]; then
            echo "Build already active in $output" >&2
            return 1
        fi
    fi
    UKE_BUILD_RUN_ID=$(cat /proc/sys/kernel/random/uuid)
    export UKE_BUILD_RUN_ID
    build_started=$(date +%s)
    build_completed=0
    build_total=21
    build_state=running
    build_stage='Starting'
    : > "$output/progress.log"
    self_pid=$BASHPID
    printf '%s\t%s\t%s\t%s\n' "$self_pid" "$(build_pid_start "$self_pid")" \
        "$UKE_BUILD_RUN_ID" "$container" > "$output/.build-run"
    rm -f -- "$output/.cancel-requested"
    build_write_status
    trap 'build_finish $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

build_status() {
    [[ -s $output/status.json ]] || { echo "No build status in $output" >&2; return 1; }
    jq -r '"\(.state): [\(.completed)/\(.total)] \(.stage); elapsed \(((now - .started_unix)/60)|floor) min"' \
        "$output/status.json"
}

build_stop() {
    local pid start id runtime
    [[ -f $output/.build-run ]] || { echo "No active build in $output" >&2; return 1; }
    IFS=$'\t' read -r pid start id runtime < "$output/.build-run"
    [[ $pid =~ ^[1-9][0-9]*$ && $start =~ ^[0-9]+$ && $id =~ ^[0-9a-f-]+$ ]] || {
        echo 'Invalid build identity' >&2; return 1;
    }
    [[ $runtime == docker || $runtime == podman ]] || { echo 'Invalid container runtime' >&2; return 1; }
    : > "$output/.cancel-requested"
    UKE_BUILD_RUN_ID=$id
    container=$runtime
    if [[ $(build_pid_start "$pid") != "$start" ]]; then
        [[ -n $(build_containers) ]] || {
            rm -f -- "$output/.cancel-requested"
            echo 'Build process and containers are no longer active' >&2; return 1;
        }
        build_stop_containers
        tmp=$(mktemp "$output/.status.XXXXXXXX")
        jq --argjson updated "$(date +%s)" \
            '.state="cancelled" | .stage="Stopped orphaned build container" | .updated_unix=$updated' \
            "$output/status.json" > "$tmp"
        chmod 0666 "$tmp"
        mv -f -- "$tmp" "$output/status.json"
        rm -f -- "$output/.build-run" "$output/.cancel-requested"
        echo "Stopped orphaned build $id"
        return
    fi
    build_stop_containers
    kill -TERM "$pid" 2>/dev/null || true
    echo "Stop requested for build $id"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    [[ $# -ge 1 && -n ${UKE_BUILD_OUTPUT:-} ]] || exit 2
    output=$UKE_BUILD_OUTPUT
    [[ -s $output/status.json ]] || exit 2
    tmp=$(mktemp "$output/.status.XXXXXXXX")
    case $1 in
        stage)
            [[ $# == 2 ]] || exit 2
            jq --arg stage "$2" --argjson updated "$(date +%s)" \
                '.stage=$stage | .updated_unix=$updated' "$output/status.json" > "$tmp"
            chmod 0666 "$tmp"
            mv -f -- "$tmp" "$output/status.json"
            jq -r '"[\(.completed)/\(.total)] \(.stage)"' "$output/status.json" | tee -a "$output/progress.log";;
        done)
            jq --argjson updated "$(date +%s)" \
                '.completed += 1 | .updated_unix=$updated' "$output/status.json" > "$tmp"
            chmod 0666 "$tmp"
            mv -f -- "$tmp" "$output/status.json";;
        *) rm -f -- "$tmp"; exit 2;;
    esac
fi

#!/usr/bin/env bash
# Host cache for byte-identical inputs used by older pinned source producers.
public_source_inputs() {
    local source=$1 mirrors=$2 name digest url input
    local manifest=$source/packaging/families/source-inputs.json
    jq -e 'type=="array" and all(.[];(.name|test("^[A-Za-z0-9+_.-]+$")) and (.sha256|test("^[a-f0-9]{64}$")))' "$manifest" > /dev/null || return
    while IFS=$'\t' read -r name digest; do
        input=$source/packaging/families/source-cache/inputs/$name.src.rpm
        if [[ ! -s $input ]]; then
            [[ ${UKE_OFFLINE:-0} != 1 ]] || { echo 'Offline source input is missing' >&2; return 1; }
            url=$(jq -er --arg name "$name" --arg digest "$digest" '[.[]|select(.name==$name and .sha256==$digest)]|if length==1 then .[0].url else error("Unmapped source input") end' "$mirrors") || return
            [[ $url == https://github.com/MCC45TR/uke-linux-hardware-support/releases/download/copr-migration-archive-20261020/*.src.rpm ]] || return 1
            mkdir -p -- "$(dirname -- "$input")" || return
            curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 300 "$url" -o "$input.part" || return
            printf '%s  %s\n' "$digest" "$input.part" | sha256sum -c - || return
            mv -- "$input.part" "$input" || return
        fi
        printf '%s  %s\n' "$digest" "$input" | sha256sum -c - || return
    done < <(jq -r '.[]|[.name,.sha256]|@tsv' "$manifest")
}

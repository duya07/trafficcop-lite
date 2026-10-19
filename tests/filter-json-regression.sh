#!/usr/bin/env bash
# Regression for iproute2 versions whose fw printer emits plaintext inside -j output.
# shellcheck disable=SC2034,SC2317

test_single_port_filter_json_excludes_unrelated_fw_printer() {
    local work
    work=$(mktemp -d "$TEST_ROOT/filter-json.XXXXXX") || return 1
    load_function "$MONITOR_SCRIPT" dog_single_port_filters_complete || return 1
    local filter4 filter6 fail_query=false
    filter4=$(jq -cn '[266,1266] | map(. as $pref | [
        {protocol:"ip",kind:"u32",pref:$pref,options:{flowid:"1:1000",match:{value:"cc10000",mask:"ffff0000",off:20}}},
        {protocol:"ip",kind:"u32",pref:$pref,options:{flowid:"1:1000",match:{value:"cc1",mask:"ffff",off:20}}}
    ]) | add') || return 1
    filter6=$(jq -cn '["tcp","udp"] | map(. as $proto | ["src_port","dst_port"] | map(
        {protocol:"ipv6",kind:"flower",options:{classid:"1:1000",keys:({ip_proto:$proto} + {(.):3265})}}
    )) | add') || return 1
    TC_BIN=mock_scoped_filter_json
    mock_scoped_filter_json() {
        [ "$fail_query" = false ] || return 55
        case " $* " in
            *' protocol ip '*) printf '%s\n' "$filter4" ;;
            *' protocol ipv6 '*) printf '%s\n' "$filter6" ;;
            *) printf '%s\n' '[{"protocol":"all","kind":"fw","options":{handle 0x501ec000/0xfffff000 classid 1:1ec }}]' ;;
        esac
    }
    dog_single_port_filters_complete eth0 3265 1:1000 || return 1
    # tc suppresses the protocol field when the dump is already protocol-scoped.
    filter4=$(jq 'map(del(.protocol))' <<< "$filter4") || return 1
    filter6=$(jq 'map(del(.protocol))' <<< "$filter6") || return 1
    dog_single_port_filters_complete eth0 3265 1:1000 || return 1
    local original4="$filter4" original6="$filter6"
    filter4=$(jq '.[1:]' <<< "$filter4") || return 1
    if dog_single_port_filters_complete eth0 3265 1:1000; then return 1; fi
    filter4="$original4"
    filter6=$(jq '.[0].options.keys.src_port = 9999' <<< "$filter6") || return 1
    if dog_single_port_filters_complete eth0 3265 1:1000; then return 1; fi
    filter6="$original6"
    filter4=$(jq '.[0].protocol = "ipv6"' <<< "$filter4") || return 1
    if dog_single_port_filters_complete eth0 3265 1:1000; then return 1; fi
    filter4="$original4"
    fail_query=true
    local result=0
    dog_single_port_filters_complete eth0 3265 1:1000 || result=$?
    [ "$result" -eq 2 ]
}

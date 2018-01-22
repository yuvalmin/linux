#!/bin/bash

NUM_NETIFS=2
source ../../../net/forwarding/lib.sh
source devlink_lib_spectrum.sh

nt=""
gc_thresh3=""
gc_thresh3_v6=""
max_allowed=200000

interface_up()
{
	ip link set dev "$h1" up
	ip address add 198.51.2.2/24 dev "$h1"
	ip link set dev "$h2" up
	ip address add 198.51.2.3/24 dev "$h2"
}

interface_down()
{
	ip address del 198.51.2.2/24 dev "$h1"
	ip link set dev "$h1" down
	ip address del 198.51.2.3/24 dev "$h2"
	ip link set dev "$h2" down
}

setup_prepare()
{
	h1=${NETIFS[p1]}
	h2=${NETIFS[p2]}

	devlink_spectrum_read_kvd_defaults
	gc_thresh3=$(cat /proc/sys/net/ipv4/neigh/default/gc_thresh3)
	gc_thresh3_v6=$(cat /proc/sys/net/ipv6/neigh/default/gc_thresh3)
	echo $((max_allowed)) > /proc/sys/net/ipv4/neigh/default/gc_thresh3
	echo $((max_allowed)) > /proc/sys/net/ipv6/neigh/default/gc_thresh3

	interface_up
}

cleanup()
{
	pre_cleanup
	interface_down

	devlink_spectrum_size_kvd_to_default
	echo "$gc_thresh3" >/proc/sys/net/ipv4/neigh/default/gc_thresh3
	echo "$gc_thresh3_v6" >/proc/sys/net/ipv6/neigh/default/gc_thresh3

	RET=0
}

test_neighbor_entry()
{
	local addr="\"$1\""
	local lladdr="\"$2\""
	local entry=$(echo $nt | jq ".[] | select(.[\"action_value\"][0].value == $lladdr)")


	if [ -z "$entry" ] || [ "$entry" == "" ]; then
		return 1
	fi

	local f_addr=$(echo "$entry" | jq ".[\"match_value\"][1][\"value\"]")

	local f_lladdr=$(echo "$entry" | jq ".[\"action_value\"][0][\"value\"]")

	#TODO - check interface
	[ "$f_addr" == "$addr" ] && [ "$f_lladdr" == "$lladdr" ]
}

test_neighbor()
{
	local count=$1
	local ip=$2
	local TD_FILE=$(mktemp)
	local addr="", lladdr="", table="", i

	if [ "$ip" == "ipv4" ]; then
		table="mlxsw_host4"
	else
		table="mlxsw_host6"
	fi

	if [ "$count" -gt "$max_allowed" ]; then
		check_err 1 "Can't test $count neighbors"
		return 1
	fi

	for i in $(seq 0 $((count - 1))); do
		if [ "$ip" == "ipv4" ]; then
			addr="192.$((i / 65536)).$(((i / 256) % 256)).$((i % 256))"
		else
			addr="2001:db8:1::$((i / 9999)):$((i % 9999))"
		fi
		lladdr="10:20:30:$((i / 10000)):$(((i / 100) % 100)):$((i % 100))"
		echo "n add $addr lladdr $lladdr dev $h1 nud permanent" >> "$TD_FILE"
	done
	ip -b "$TD_FILE"

	sleep 1

	local size=$(devlink_dpipe_table_show $table | jq ".size")
	if [ "$size" -ne "$count" ]; then
		check_err 1 "expected $count dpipe entries but only $size were added"
		return 1
	fi

	# FIXME: We currently fail if try to return too many entries in table;
	# so skip in this case
	if [ "$size" -gt 500 ]; then
		sed -e "s/ add/ del/" -i "$TD_FILE"
		ip -b "$TD_FILE"
		ip n flush dev "$h1"
		rm -rf "$TD_FILE"
		return 0;
	fi

	nt=$(devlink_dpipe_table_dump $table)

	for i in $(seq 0 $((count - 1))); do
		if [ "$ip" == "ipv4" ]; then
			addr="192.$((i / 65536)).$(((i / 256) % 256)).$((i % 256))"
		else
			if [ "$i" -eq 0 ]; then
				addr="2001:db8:1::"
			elif [ "$i" -lt 10000 ]; then
				addr="2001:db8:1::$((i % 9999))"
			else
				addr="2001:db8:1::$((i / 9999)):$((i % 9999))"
			fi
		fi
		lladdr="10:20:30:$((i / 10000)):$(((i / 100) % 100)):$((i % 100))"

		if ! test_neighbor_entry "$addr" "$lladdr"; then
			RET=1
			retmsg="$addr: $lladdr : FAILED"
			break
		fi
	done

	sed -e "s/ add/ del/" -i "$TD_FILE"
	ip -b "$TD_FILE"
	ip n flush dev "$h1"

	if [ "$RET" -eq 0 ]; then
		rm -rf "$TD_FILE"
	else
		retmsg="$retmsg; Log is at $TD_FILE"
	fi
}

test_neighbor_profile()
{
	profile=$1

	devlink_spectrum_resource_set_kvd_profile "$profile"
	interface_up
	setup_wait 2

	# TODO - Validate numbers are meetign some minimum value;
	# First need to determine that minimum
	target=$(devlink_spectrum_resource_size_by_kvd_dpipe_table mlxsw_host4)
	target=$(((target * 90) / 100))
	test_neighbor "$target" ipv4
	log_test "Setting $target Permanent IPv4 neighbours [$profile]"

	target=$(devlink_spectrum_resource_size_by_kvd_dpipe_table mlxsw_host6)
	target=$(((target * 90) / 200))
	test_neighbor "$target" ipv6
	log_test "Setting $target Permanent IPv6 neighbours [$profile]"
}

trap cleanup EXIT

setup_prepare

test_neighbor_profile "default"
test_neighbor_profile "scale"
test_neighbor_profile "ipv4_max"

exit $RET

#!/bin/bash

NUM_NETIFS=4
source ../../../net/forwarding/lib.sh

support_devlink=0
if [ -n "$DEVLINK_DEV" ] && [ "$DEVLINK_VIDDID" == "15b3:cb84" ]; then
	support_devlink=1
	source devlink_lib_spectrum.sh
fi

h1_create()
{
	vrf_create "vrf-h1" 1
	ip link set dev "$h1" master vrf-h1

	ip link set dev vrf-h1 up
	ip link set dev "$h1" up

	ip address add 198.51.2.2/24 dev "$h1"
}

h1_destroy()
{
	ip address del 198.51.2.2/24 dev "$h1"

	ip link set dev "$h1" down
	vrf_destroy "vrf-h1" 1
}

h2_create()
{
	vrf_create "vrf-h2" 2
	ip link set dev "$h2" master vrf-h2

	ip link set dev vrf-h2 up
	ip link set dev "$h2" up

	ip address add 198.51.2.3/24 dev "$h2"
}

h2_destroy()
{
	ip address del 198.51.2.3/24 dev "$h2"

	ip link set dev "$h2" down
	vrf_destroy "vrf-h2" 2
}

bridge_create()
{
	ip link add dev brx type bridge
	ip link set dev brx type bridge vlan_filtering 1
	ip link set dev brx type bridge ageing_time 60000
	ip link set dev "$bp1" master brx
	ip link set dev "$bp2" master brx
	ip link set dev "$bp1" up
	ip link set dev "$bp2" up
	ip link set dev brx up
}

bridge_destroy()
{
	ip link del dev brx
	ip link set dev "$bp2" down
	ip link set dev "$bp1" down
}

setup_prepare()
{
	h1=${NETIFS[p1]}
	bp1=${NETIFS[p2]}

	bp2=${NETIFS[p3]}
	h2=${NETIFS[p4]}

	netifs_arr=($h1 $bp1 $bp2 $h2)

	vrf_prepare

	h1_create
	h2_create

	bridge_create

	forwarding_enable
}

first_setup_prepare()
{
	if [ "$support_devlink" -eq 1 ]; then
		devlink_spectrum_read_kvd_defaults
	fi

	setup_prepare
}

non_final_cleanup()
{
	forwarding_restore

	bridge_destroy

	h2_destroy
	h1_destroy

	vrf_cleanup

	RET=0
}

cleanup()
{
	pre_cleanup
	non_final_cleanup

	if [ "$support_devlink" -eq 1 ]; then
		devlink_spectrum_size_kvd_to_default
	fi
}

# Generate packets with various source MAC addresses and check the
# MACs are learned by the bridge.
# The major difficulty in this design is that mausezahn doesn't support
# mac-range, only random MACs. As a result we can't pre-generate the
# expected list of MACs to the learned, instead having to resolve into
# using tcpdump to capture those packets and prepare a list.

test_fdb()
{
	local COUNT=$1
	local FREEDOM=$2
	local FDB=""
	local delay_pkts=50
	local TD_FILE=$(mktemp)

	# Spectrum currently supports ~640 MACs/sec when learning
	if [ "$support_devlink" -eq 1 ]; then
		delay_pkts=2000
	fi

	tcpdump -i "$h1" -nn -s 20 -c "$COUNT" \
		-e ether dst 10:20:30:40:50:60 > "$TD_FILE" 2>/dev/null &
	tcpdump_ps=$!

	# Need to make sure the filter is already in place; Since we don't
	# have a very good method, simply wait a bit
	sleep 2

	ip vrf exec vrf-h1 mausezahn "$h1" -p 64 -A 198.51.2.2 -B 198.51.2.3 \
				     -d "$delay_pkts" \
				     -t udp "sp=1024,dp=1024" -a rand \
				     -b "10:20:30:40:50:60" -c "$COUNT" \
				     &>/dev/null
	sleep 3

	if [ -n "$(ps -p "$tcpdump_ps" -o pid=)" ]; then
		check_err 1 "TCPDUMP is still running [$(wc --lines < "$TD_FILE")/$COUNT]"
		sleep 1
		kill -9 "$tcpdump_ps" &>/dev/null
	fi

	if [ "$support_devlink" -eq "1" ]; then
		FDB=$(bridge fdb show brport "$bp1" | grep offload | \
		      cut -d" " -f1 | sort | uniq)
	else
		FDB=$(bridge fdb show brport "$bp1" | cut -d" " -f1 | \
		      sort | uniq)
	fi
	readarray -t FDB_ARRAY <<< "$FDB"
	MAC=$(cut -d" " -f2 "$TD_FILE" | sort | uniq)

	local fdb_index=0
	for mac in $MAC; do
		if [ "$RET" -ne 0 ]; then
			break
		fi

		while [ "$fdb_index" -lt ${#FDB_ARRAY[@]} ]; do
			if [ "$mac" == "${FDB_ARRAY[$fdb_index]}" ]; then
				COUNT=$((COUNT - 1))
				fdb_index=$((fdb_index + 1))
				break
			elif [ "$mac" \> "${FDB_ARRAY[$fdb_index]}" ]; then
				fdb_index=$((fdb_index + 1))
				continue
			else
				check_err 1 "Failed to find a match to $mac"
				break
			fi
		done

		if [ "$COUNT" -eq 0 ]; then
			break
		fi
	done

	if [ "$COUNT" -gt "$FREEDOM" ]; then
		check_err 1 "$COUNT MACs are not matched"
	fi

	if [ "$RET" -eq 0 ]; then
		rm -rf "$TD_FILE"
	else
		echo "$FDB" | tr ' ' '\n'>  "${TD_FILE}.fdb"
		bridge fdb show brport "$bp1" > "${TD_FILE}.fdb_now"
		retmsg="$retmsg; Failed logs at ${TD_FILE}*"
	fi
}

test_fdb_profile()
{
	profile=$1
	target=$2

	if [ "$support_devlink" -eq 1 ]; then
		non_final_cleanup
		devlink_spectrum_resource_set_kvd_profile "$profile"
		setup_prepare
	else
		bridge_destroy
		bridge_create
	fi

	setup_wait 4

	test_fdb "$target" 10

	if [ "$support_devlink" -eq 1 ]; then
		log_test "$((target / 1000))K MAC test [$profile]"
	else
		log_test "$((target / 1000))K MAC test"
	fi
}

trap cleanup EXIT

first_setup_prepare

test_fdb_profile "scale" 100000
test_fdb_profile "ipv4_max" 120000
test_fdb_profile "default" 75000

exit $RET

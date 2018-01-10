#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

NUM_NETIFS=2
source lib.sh

tcflags="skip_hw"

h1_create()
{
	vrf_create "vrf-h1" 1
	ip link set dev $h1 master vrf-h1

	ip link set dev vrf-h1 up
	ip link set dev $h1 up

	ip address add 192.0.2.1/24 dev $h1
	ip address add 198.51.100.1/24 dev $h1
	ip address add 2001:db8:1::1/64 dev $h1

	tc qdisc add dev $h1 clsact
}

h1_destroy()
{
	tc qdisc del dev $h1 clsact

	ip address del 2001:db8:1::1/64 dev $h1
	ip address del 198.51.100.1/24 dev $h1
	ip address del 192.0.2.1/24 dev $h1

	ip link set dev $h1 down
	vrf_destroy "vrf-h1" 1
}

h2_create()
{
	vrf_create "vrf-h2" 2
	ip link set dev $h2 master vrf-h2

	ip link set dev vrf-h2 up
	ip link set dev $h2 up

	ip address add 192.0.2.2/24 dev $h2
	ip address add 198.51.100.2/24 dev $h2
	ip address add 2001:db8:1::2/64 dev $h2

	tc qdisc add dev $h2 clsact
}

h2_destroy()
{
	tc qdisc del dev $h2 clsact

	ip address del 2001:db8:1::2/64 dev $h2
	ip address del 198.51.100.2/24 dev $h2
	ip address del 192.0.2.2/24 dev $h2

	ip link set dev $h2 down
	vrf_destroy "vrf-h2" 2
}

match_dst_mac_test()
{
	local dummy_mac=de:ad:be:ef:aa:aa

	RET=0

	tc filter add dev $h2 ingress protocol ip pref 1 handle 101 flower \
		$tcflags dst_mac $dummy_mac action drop
	tc filter add dev $h2 ingress protocol ip pref 2 handle 102 flower \
		$tcflags dst_mac $h2mac action drop

	mausezahn $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[] | select(.options.handle == 101 \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_fail $? "matched on a wrong filter"

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[] | select(.options.handle == 102) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "did not match on correct filter"

	tc filter del dev $h2 ingress protocol ip pref 1 handle 101 flower
	tc filter del dev $h2 ingress protocol ip pref 2 handle 102 flower

	print_result "dst_mac match ($tcflags)"
}

match_src_mac_test()
{
	local dummy_mac=de:ad:be:ef:aa:aa

	RET=0

	tc filter add dev $h2 ingress protocol ip pref 1 handle 101 flower \
		$tcflags src_mac $dummy_mac action drop
	tc filter add dev $h2 ingress protocol ip pref 2 handle 102 flower \
		$tcflags src_mac $h1mac action drop

	mausezahn $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[] | select(.options.handle == 101) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_fail $? "matched on a wrong filter"

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[] | select(.options.handle == 102) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "did not match on correct filter"

	tc filter del dev $h2 ingress protocol ip pref 1 handle 101 flower
	tc filter del dev $h2 ingress protocol ip pref 2 handle 102 flower

	print_result "src_mac match ($tcflags)"
}

match_dst_ip_test()
{
	RET=0

	tc filter add dev $h2 ingress protocol ip pref 1 handle 101 flower \
		$tcflags dst_ip 198.51.100.2 action drop
	tc filter add dev $h2 ingress protocol ip pref 2 handle 102 flower \
		$tcflags dst_ip 192.0.2.2 action drop
	tc filter add dev $h2 ingress protocol ip pref 3 handle 103 flower \
		$tcflags dst_ip 192.0.2.0/24 action drop

	mausezahn $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[] \
		| select(.options.handle == 101) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_fail $? "matched on a wrong filter"

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[]  \
		| select(.options.handle == 102) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "did not match on correct filter"

	tc filter del dev $h2 ingress protocol ip pref 2 handle 102 flower

	mausezahn $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[] \
		| select(.options.handle == 103) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "did not match on correct filter with mask"

	tc filter del dev $h2 ingress protocol ip pref 1 handle 101 flower
	tc filter del dev $h2 ingress protocol ip pref 3 handle 103 flower

	print_result "dst_ip match ($tcflags)"
}

match_src_ip_test()
{
	RET=0

	tc filter add dev $h2 ingress protocol ip pref 1 handle 101 flower \
		$tcflags src_ip 198.51.100.1 action drop
	tc filter add dev $h2 ingress protocol ip pref 2 handle 102 flower \
		$tcflags src_ip 192.0.2.1 action drop
	tc filter add dev $h2 ingress protocol ip pref 3 handle 103 flower \
		$tcflags src_ip 192.0.2.0/24 action drop

	mausezahn $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[] \
		| select(.options.handle == 101) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_fail $? "matched on a wrong filter"

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[] \
		| select(.options.handle == 102) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "did not match on correct filter"

	tc filter del dev $h2 ingress protocol ip pref 2 handle 102 flower

	mausezahn $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[] \
		| select(.options.handle == 103) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "did not match on correct filter with mask"

	tc filter del dev $h2 ingress protocol ip pref 1 handle 101 flower
	tc filter del dev $h2 ingress protocol ip pref 3 handle 103 flower

	print_result "src_ip match ($tcflags)"
}

setup_prepare()
{
	h1=${NETIFS[p1]}
	h2=${NETIFS[p2]}
	h1mac=$(mac_get $h1)
	h2mac=$(mac_get $h2)

	if [[ "${OPTIONS[noprepare]}" == "yes" ]]; then
		echo "INFO: Not doing setup prepare"
		return 0
	fi

	vrf_prepare

	h1_create
	h2_create
}

cleanup()
{
	if [[ "${OPTIONS[nocleanup]}" == "yes" ]]; then
		echo "INFO: Not doing cleanup"
		return 0
	fi

	h2_destroy
	h1_destroy

	vrf_cleanup
}

trap cleanup EXIT

setup_prepare
setup_wait

match_dst_mac_test
match_src_mac_test
match_dst_ip_test
match_src_ip_test

tc_offload_check
if [[ $? -ne 0 ]]; then
	echo "WARN: Could not test offloaded functionality"
else
	tcflags="skip_sw"
	match_dst_mac_test
	match_src_mac_test
	match_dst_ip_test
	match_src_ip_test
fi

exit $EXIT_STATUS

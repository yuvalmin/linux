#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

NUM_NETIFS=4
source lib.sh

tcflags="skip_hw"

h1_create()
{
	vrf_create "vrf-h1" 1
	ip link set dev $h1 master vrf-h1

	ip link set dev vrf-h1 up
	ip link set dev $h1 up

	ip address add 192.0.2.1/24 dev $h1
	ip address add 2001:db8:1::1/64 dev $h1

	tc qdisc add dev $h1 clsact
}

h1_destroy()
{
	tc qdisc del dev $h1 clsact

	ip address del 2001:db8:1::1/64 dev $h1
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
	ip address add 2001:db8:1::2/64 dev $h2

	tc qdisc add dev $h2 clsact
}

h2_destroy()
{
	tc qdisc del dev $h2 clsact

	ip address del 2001:db8:1::2/64 dev $h2
	ip address del 192.0.2.2/24 dev $h2

	ip link set dev $h2 down
	vrf_destroy "vrf-h2" 2
}

switch_create()
{
	vrf_create "vrf-swp1" 3
	ip link set dev $swp1 master vrf-swp1

	ip link set dev vrf-swp1 up
	ip link set dev $swp1 up

	ip address add 192.0.2.2/24 dev $swp1
	ip address add 2001:db8:1::2/64 dev $swp1

	tc qdisc add dev $swp1 clsact

	vrf_create "vrf-swp2" 4
	ip link set dev $swp2 master vrf-swp2

	ip link set dev vrf-swp2 up
	ip link set dev $swp2 up

	ip address add 192.0.2.1/24 dev $swp2
	ip address add 2001:db8:1::1/64 dev $swp2

	tc qdisc add dev $swp2 clsact
}

switch_destroy()
{
	tc qdisc del dev $swp1 clsact

	ip address del 2001:db8:1::2/64 dev $swp1
	ip address del 192.0.2.2/24 dev $swp1

	ip link set dev $swp1 down
	vrf_destroy "vrf-swp1" 3

	tc qdisc del dev $swp2 clsact

	ip address del 2001:db8:1::1/64 dev $swp2
	ip address del 192.0.2.1/24 dev $swp2

	ip link set dev $swp2 down
	vrf_destroy "vrf-swp2" 4
}

mirred_egress_redirect_test()
{
	RET=0

	tc filter add dev $h2 ingress protocol ip pref 1 handle 101 flower \
		$tcflags dst_ip 192.0.2.2 action drop

	$MZ $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[]  \
		| select(.options.handle == 101) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_fail $? "Matched without redirect rule inserted"

	tc filter add dev $swp1 ingress protocol ip pref 1 handle 101 flower \
		$tcflags dst_ip 192.0.2.2 action mirred egress redirect \
		dev $swp2

	$MZ $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $h2 ingress \
		| jq -e ".[]  \
		| select(.options.handle == 101) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "Did not match incoming redirected packet"

	tc filter del dev $swp1 ingress protocol ip pref 1 handle 101 flower
	tc filter del dev $h2 ingress protocol ip pref 1 handle 101 flower

	log_test "Mirred egress redirect ($tcflags)"
}

gact_drop_and_ok_test()
{
	RET=0

	tc filter add dev $swp1 ingress protocol ip pref 2 handle 102 flower \
		skip_hw dst_ip 192.0.2.2 action drop

	$MZ $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $swp1 ingress \
		| jq -e ".[]  \
		| select(.options.handle == 102) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "Packet was not dropped"

	tc filter add dev $swp1 ingress protocol ip pref 1 handle 101 flower \
		$tcflags dst_ip 192.0.2.2 action ok

	$MZ $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $swp1 ingress \
		| jq -e ".[]  \
		| select(.options.handle == 101) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "Did not see trapped packet"

	tc filter del dev $swp1 ingress protocol ip pref 2 handle 102 flower
	tc filter del dev $swp1 ingress protocol ip pref 1 handle 101 flower

	log_test "gact drop and ok ($tcflags)"
}

gact_trap_test()
{
	RET=0

	tc filter add dev $swp1 ingress protocol ip pref 1 handle 101 flower \
		skip_hw dst_ip 192.0.2.2 action drop
	tc filter add dev $swp1 ingress protocol ip pref 3 handle 103 flower \
		$tcflags dst_ip 192.0.2.2 action mirred egress redirect \
		dev $swp2

	$MZ $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $swp1 ingress \
		| jq -e ".[]  \
		| select(.options.handle == 101) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_fail $? "Saw packet without trap rule inserted"

	tc filter add dev $swp1 ingress protocol ip pref 2 handle 102 flower \
		$tcflags dst_ip 192.0.2.2 action trap

	$MZ $h1 -c 1 -p 64 -a $h1mac -b $h2mac -A 192.0.2.1 -B 192.0.2.2 \
		-t ip -q

	tc -j -s filter show dev $swp1 ingress \
		| jq -e ".[]  \
		| select(.options.handle == 102) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "Packet was not trapped"

	tc -j -s filter show dev $swp1 ingress \
		| jq -e ".[]  \
		| select(.options.handle == 101) \
		| select(.options.actions[0].stats.packets == 1)" &> /dev/null
	check_err $? "Did not see trapped packet"

	tc filter del dev $swp1 ingress protocol ip pref 3 handle 103 flower
	tc filter del dev $swp1 ingress protocol ip pref 2 handle 102 flower
	tc filter del dev $swp1 ingress protocol ip pref 1 handle 101 flower

	log_test "trap ($tcflags)"
}

setup_prepare()
{
	h1=${NETIFS[p1]}
	swp1=${NETIFS[p2]}

	swp2=${NETIFS[p3]}
	h2=${NETIFS[p4]}

	h1mac=$(mac_get $h1)
	h2mac=$(mac_get $h2)

	swp1origmac=$(mac_get $swp1)
	swp2origmac=$(mac_get $swp2)
	ip link set $swp1 address $h2mac
	ip link set $swp2 address $h1mac

	vrf_prepare

	h1_create
	h2_create
	switch_create
}

cleanup()
{
	pre_cleanup

	switch_destroy
	h2_destroy
	h1_destroy

	vrf_cleanup

	ip link set $swp2 address $swp2origmac
	ip link set $swp1 address $swp1origmac
}

trap cleanup EXIT

setup_prepare
setup_wait

gact_drop_and_ok_test
mirred_egress_redirect_test

tc_offload_check
if [[ $? -ne 0 ]]; then
	log_info "Could not test offloaded functionality"
else
	tcflags="skip_sw"
	gact_drop_and_ok_test
	mirred_egress_redirect_test
	gact_trap_test
fi

exit $EXIT_STATUS

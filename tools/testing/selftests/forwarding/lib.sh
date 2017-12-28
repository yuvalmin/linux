#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

if [[ "$(id -u)" -ne 0 ]]; then
	echo "SKIP: need root privileges"
	exit 0
fi

if [[ ! -f forwarding.config ]]; then
	echo "SKIP: could not find configuration file"
	exit 0
fi

tc -j &> /dev/null
if [[ $? -ne 0 ]]; then
	echo "SKIP: iproute2 too old, missing JSON support"
	exit 0
fi

if [[ ! -x "$(command -v jq)" ]]; then
	echo "SKIP: jq not installed"
	exit 0
fi

if [[ ! -x "$(command -v mausezahn)" ]]; then
	echo "SKIP: mausezahn not installed"
	exit 0
fi

if [[ ! -v NUM_NETIFS ]]; then
	echo "SKIP: importer does not define \"NUM_NETIFS\""
	exit 0
fi

source forwarding.config

for i in $(eval echo {1..$NUM_NETIFS}); do
	ip link show dev ${NETIFS[p$i]} &> /dev/null
	if [[ $? -ne 0 ]]; then
		echo "SKIP: could not find all required interfaces"
		exit 0
	fi
done

# Exit status to return at the end. Set in case one of the tests fails.
EXIT_STATUS=0
# Per-test return value. Clear at the beginning of each test.
RET=0

### Helpers ###

check_err()
{
	local err=$1
	local msg=$2

	if [[ $RET -eq 0 ]]; then
		RET=$err
		retmsg=$msg
	fi
}

check_fail()
{
	local err=$1
	local msg=$2

	if [[ $err -eq 0 ]]; then
		RET=1
		retmsg=$msg
	fi
}

print_result()
{
	local test_name=$1
	local opt_str=$2

	if [[ $# -eq 2 ]]; then
		opt_str="($opt_str)"
	fi

	if [[ $RET -ne 0 ]]; then
		EXIT_STATUS=1
		echo "FAIL: $test_name $opt_str"
		if [[ ! -z "$retmsg" ]]; then
			echo "$retmsg"
		fi
		return 1
	fi

	echo "PASS: $test_name $opt_str"
	return 0
}

setup_wait()
{
	for i in $(eval echo {1..$NUM_NETIFS}); do
		while true; do
			ip link show dev ${NETIFS[p$i]} up \
				| grep 'state UP' &> /dev/null
			if [[ $? -ne 0 ]]; then
				sleep 1
			else
				break
			fi
		done
	done

	# Make sure links are ready.
	sleep ${OPTIONS[wait_time]}
}

vrf_prepare()
{
	ip -4 rule add pref 32765 table local
	ip -4 rule del pref 0
	ip -6 rule add pref 32765 table local
	ip -6 rule del pref 0
}

vrf_cleanup()
{
	ip -6 rule add pref 0 table local
	ip -6 rule del pref 32765
	ip -4 rule add pref 0 table local
	ip -4 rule del pref 32765
}

vrf_create()
{
	local vrf_name=$1
	local tb_id=$2

	ip link add dev $vrf_name type vrf table $tb_id
	ip -4 route add table $tb_id unreachable default metric 4278198272
	ip -6 route add table $tb_id unreachable default metric 4278198272
}

vrf_destroy()
{
	local vrf_name=$1
	local tb_id=$2

	ip -6 route del table $tb_id unreachable default metric 4278198272
	ip -4 route del table $tb_id unreachable default metric 4278198272
	ip link del dev $vrf_name
}

mtu_get()
{
	local if_name=$1

	ip -j link show dev $if_name | jq '.[]["mtu"]'
}

mtu_change()
{
	local new_mtu=$1
	local if_name

	shift
	for if_name in "${@}"; do
		ip link set dev $if_name mtu $new_mtu
	done
}

bridge_ageing_time_get()
{
	local ageing_time
	local bridge=$1

	# Need to divide by 100 to convert to seconds.
	ageing_time=$(ip -j -d link show dev $bridge \
		      | jq '.[]["linkinfo"]["info_data"]["ageing_time"]')
	echo $((ageing_time / 100))
}

### Tests ###

ping_test()
{
	local vrf_name=$1
	local dip=$2

	RET=0

	ip vrf exec $vrf_name ping $dip -c 10 -i 0.1 -w 2 &> /dev/null
	check_err $?
	print_result "ping"
}

learning_test()
{
	local ageing_time
	local host_if=$4
	local br_port=$2
	local bridge=$1
	local vid=$3

	RET=0

	bridge -j fdb show br $bridge brport $br_port vlan $vid \
		| jq -e '.[] | select(.mac == "de:ad:be:ef:13:37")' &> /dev/null
	check_fail $? "found FDB record when should not"

	mausezahn $host_if -c 1 -p 64 -a de:ad:be:ef:13:37 -t ip -q

	bridge -j fdb show br $bridge brport $br_port vlan $vid \
		| jq -e '.[] | select(.mac == "de:ad:be:ef:13:37")' &> /dev/null
	check_err $? "did not find FDB record when should"

	# Wait for 10 seconds after the ageing time to make sure FDB
	# record was aged-out.
	ageing_time=$(bridge_ageing_time_get $bridge)
	sleep $((ageing_time + 10))

	bridge -j fdb show br $bridge brport $br_port vlan $vid \
		| jq -e '.[] | select(.mac == "de:ad:be:ef:13:37")' &> /dev/null
	check_fail $? "found FDB record when should not"

	bridge link set dev $br_port learning off

	mausezahn $host_if -c 1 -p 64 -a de:ad:be:ef:13:37 -t ip -q

	bridge -j fdb show br $bridge brport $br_port vlan $vid \
		| jq -e '.[] | select(.mac == "de:ad:be:ef:13:37")' &> /dev/null
	check_fail $? "found FDB record when should not"

	bridge link set dev $br_port learning on

	print_result "learning"
}

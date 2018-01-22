#!/bin/bash

NUM_NETIFS=1
source ../../../net/forwarding/lib.sh
source devlink_lib_spectrum.sh

setup_prepare()
{
	devlink_spectrum_read_kvd_defaults
}

cleanup()
{
	pre_cleanup
	devlink_spectrum_size_kvd_to_default
}

trap cleanup EXIT

setup_prepare

# Check profiles can be set; default is tested explicitly at end to ensure the
# configuration was actully applied
for i in $KVD_PROFILES; do
	devlink_spectrum_resource_set_kvd_profile $i
	log_test "Setting profile '$i'"
done
devlink_spectrum_resource_set_kvd_profile "default"
log_test "Setting profile back to default"

# Check each resource can be independently be set to a smaller size
for i in $KVD_CHILDREN; do
	size=$(devlink_resource_get_min kvd "$i")
	devlink_spectrum_set_size_min $i
	devlink_reload 1
	devlink_spectrum_size_kvd_to_default
	log_test "Minimize $i [$size]"
done

# Check each resource can be increased while reducing other
# Check 3 scenarios - almost filling KVD, exactly filling KVD and overflow
for i in $KVD_CHILDREN; do
	devlink_spectrum_resource_set_all_kvd_min

	size=$(devlink_spectrum_resource_get_remaining_kvd_size "$i")
	devlink_resource_set_size "$((size - 128))" 1 kvd "$i"
	devlink_reload 1
	log_test "Almost maximize $i [$((size - 128))]"


	devlink_resource_set_size "$((size + 128))" 0 kvd "$i"
	log_test "Overflow $i [$((size + 128))] is rejected"

	#FIXME
	if [ "$i" == "hash_single" ] || [ "$i" == "hash_double" ]; then
		echo "SKIP: Observed problem with Max $i"
		continue
	fi

	devlink_resource_set_size "$size" 1 kvd "$i"
	devlink_reload 1
	log_test "Maximize $i [$size]"
done
devlink_spectrum_size_kvd_to_default

exit "$RET"

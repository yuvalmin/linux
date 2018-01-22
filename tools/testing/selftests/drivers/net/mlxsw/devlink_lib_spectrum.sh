#!/bin/bash

# Dependency issue; Assume lib.sh is already included
# [as includer most likely would usually need DEVLINK_VIDDID
#  tested before including this]

source devlink_lib.sh

if [ "$DEVLINK_VIDDID" != "15b3:cb84" ]; then
	echo "SKIP: test is tailored for Mellanox Spectrum"
	exit 0
fi

# Needed for returning to default
declare -A KVD_DEFAULTS

KVD_CHILDREN="linear hash_single hash_double"
KVDL_CHILDREN="singles chunks large_chunks"

# Get the MAX value you can set for a given entry given the values
# in the same layer of the hierarchy of other resources
devlink_spectrum_resource_get_remaining_kvd_size()
{
	local current=$1
	local total_size=$(devlink_resource_get_size kvd)
	local size
	local i

	for i in $KVD_CHILDREN; do
		if [ "$i" != "$current" ]; then
			size=$(devlink_resource_get_min kvd "$i")
			total_size=$((total_size - size))
		fi
	done

	echo "$total_size"
}

devlink_spectrum_resource_set_all_kvd_min()
{
	local size
	local i

	for i in $KVD_CHILDREN; do
		size=$(devlink_resource_get_min kvd "$i")
		devlink_resource_set_size "$size" 1 kvd "$i"
	done

	for i in $KVDL_CHILDREN; do
		size=$(devlink_resource_get_min kvd linear "$i")
		devlink_resource_set_size "$size" 1 kvd linear "$i"
	done
}

devlink_spectrum_size_kvd_to_default()
{
	local need_reload=0
	local i

	for i in $KVD_CHILDREN; do
		local size=$(echo "${KVD_DEFAULTS[kvd_$i]}" | jq '.["size"]')
		current_size=$(devlink_resource_get_size kvd "$i")

		if [ "$size" -ne "$current_size" ]; then
			devlink_resource_set_size "$size" 1 kvd "$i"
			need_reload=1
		fi
	done

	for i in $KVDL_CHILDREN; do
		local size=$(echo "${KVD_DEFAULTS[kvd_linear_$i]}" | jq '.["size"]')
		current_size=$(devlink_resource_get_size kvd linear "$i")

		if [ "$size" -ne "$current_size" ]; then
			devlink_resource_set_size "$size" 1 kvd linear "$i"
			need_reload=1
		fi
	done

	if [ "$need_reload" -ne "0" ]; then
		devlink_reload 1
	fi
}

devlink_spectrum_read_kvd_defaults()
{
	local i

	KVD_DEFAULTS[kvd]=$(devlink_resource_get "kvd")
	for i in $KVD_CHILDREN; do
		KVD_DEFAULTS[kvd_$i]=$(devlink_resource_get kvd "$i")
	done

	for i in $KVDL_CHILDREN; do
		KVD_DEFAULTS[kvd_linear_$i]=$(devlink_resource_get kvd linear "$i")
	done
}

devlink_spectrum_set_size_min()
{
	local kvd_resource=$1
	local i

	local size=$(devlink_resource_get_min kvd "$kvd_resource")
	devlink_resource_set_size "$size" 1 kvd "$kvd_resource"

	# In case of linear, need to minimize sub-resources as well
	if [[ "$kvd_resource" == "linear" ]]; then
		for i in $KVDL_CHILDREN; do
			devlink_resource_set_size 0 1 kvd "$kvd_resource" "$i"
		done
	fi
}

KVD_PROFILES="default scale ipv4_max"

devlink_spectrum_resource_set_kvd_profile()
{
	local profile=$1

	case "$profile" in
		scale)
			devlink_resource_set_size 64000 1 kvd linear
			devlink_resource_set_size 15616 1 kvd linear singles
			devlink_resource_set_size 32000 1 kvd linear chunks
			devlink_resource_set_size 16384 1 kvd linear large_chunks
			devlink_resource_set_size 128000 1 kvd hash_single
			devlink_resource_set_size 48000 1 kvd hash_double
			devlink_reload 1
			;;
		ipv4_max)
			devlink_resource_set_size 64000 1 kvd linear
			devlink_resource_set_size 15616 1 kvd linear singles
			devlink_resource_set_size 32000 1 kvd linear chunks
			devlink_resource_set_size 16384 1 kvd linear large_chunks
			devlink_resource_set_size 144000 1 kvd hash_single
			devlink_resource_set_size 32768 1 kvd hash_double
			devlink_reload 1
			;;
		default)
			devlink_resource_set_size 98304 1 kvd linear
			devlink_resource_set_size 16384 1 kvd linear singles
			devlink_resource_set_size 49152 1 kvd linear chunks
			devlink_resource_set_size 32768 1 kvd linear large_chunks
			devlink_resource_set_size 87040 1 kvd hash_single
			devlink_resource_set_size 60416 1 kvd hash_double
			devlink_reload 1
			;;
		*)
			RET=1
			retmsg="Failed to set profile to $profile"
	esac
}

devlink_spectrum_resource_size_by_kvd_dpipe_table()
{
	local name=$1

	devlink -j -p resource show "$DEVLINK_DEV" | \
		jq ".resources[\"$DEVLINK_DEV\"][] | \
		    select(.name == \"kvd\") | .resources[] | \
		    select(.dpipe_tables[].table_name == \"$name\").size"
}

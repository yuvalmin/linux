#!/bin/bash

# Dependency issue; Assume lib.sh is already included
# [as includer most likely would usually need DEVLINK_DEV
#  tested before including this]

if [ -z "$DEVLINK_DEV" ]; then
	echo "SKIP: ${NETIFS[p1]} has no devlink device registered for it"
	exit 0
fi

devlink -j -p resource show "$DEVLINK_DEV" &> /dev/null
if [ $? -ne 0 ]; then
	echo "SKIP: devlink doesn't support 'resource show'"
	exit 0
fi

devlink_resource_names_to_path()
{
	local path=""
	for resource in "${@}"; do
		if [ "$path" == "" ]; then
			path="$resource"
		else
			path="${path}/$resource"
		fi
	done

	echo "$path"
}

devlink_resource_get()
{
	local resource_name=.[][\"$DEVLINK_DEV\"]
	resource_name="$resource_name | .[] | select (.name == \"$1\")"

	shift
	for resource in "${@}"; do
		resource_name="${resource_name} | .[\"resources\"][] | select (.name == \"$resource\")"
	done

	devlink -j -p resource show "$DEVLINK_DEV" | jq "$resource_name"
}

devlink_resource_get_min()
{
	devlink_resource_get "$@" | jq '.["size_min"]'
}

devlink_resource_get_size()
{
	local size=$(devlink_resource_get "$@" | jq '.["size_new"]')
	if [ "$size" == "null" ]; then
		devlink_resource_get "$@" | jq '.["size"]'
	else
		echo "$size"
	fi
}

devlink_resource_set_size()
{
	local new_size=$1
	local should_pass=$2
	shift
	shift
	local path=$(devlink_resource_names_to_path "$@")

	# FIXME - RM#1313582 - devlink returns success even on failure
	local result=$(devlink resource set "$DEVLINK_DEV" path "$path" \
		       size "$new_size" 2>&1)
	if [[ ($RET == 0) ]]; then
		if [[ ! -z $result && ($should_pass == 1) ]]; then
			RET=1
			retmsg="Failed to set $path to size $new_size"
		elif [[ -z $result && ($should_pass == 0) ]]; then
			RET=1
			retmsg="Set $path to size $new_size when it should have failed"
		fi
	fi
}

devlink_reload()
{
	local should_pass=$1

	devlink dev reload "$DEVLINK_DEV" &> /dev/null

	local still_pending=$(devlink -j -p resource show "$DEVLINK_DEV" | grep -c "size_new")

	if [[ ($RET == 0) ]]; then
		if [[ ($still_pending -gt 0) && ($should_pass -eq 1) ]]; then
			RET=1
			retmsg="Reload failed; There are still unset sizes"
		elif [[ ($still_pending -eq 0) && ($should_pass -eq 0) ]]; then
			RET=1
			retmsg="Reload succeed where it should have failed"
		fi
	fi
}

devlink_dpipe_table_dump()
{
	local name=$1

	devlink -j -p dpipe table dump "$DEVLINK_DEV" name "$name" | \
		jq ".[\"table_entry\"][\"$DEVLINK_DEV\"]"
}

devlink_dpipe_table_show()
{
	local name=$1

	devlink -j -p dpipe table show "$DEVLINK_DEV" | \
		jq ".[\"table\"][\"$DEVLINK_DEV\"][] | select(.name==\"$name\")"

}

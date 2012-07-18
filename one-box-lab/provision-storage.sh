#!/bin/bash

## Set some default variables here, likely will not use them all
## right now
progname=$(basename $0)
version=0.1.0
debug=1
cannot_continue=""

ZFS_CMD=/usr/sbin/zfs

OPTIND=1         # Reset in case getopts has been used previously in the shell.

# Initialize our own variables:
output_file=""
verbose=0

function show_help () {
	usage="Usage:
	${progname} [-h] [-b -r] -s <pool/dataset> -t <pool/dataset> -- program to calculate the answer to life, the universe and everything
		
		[-T <pool/dataset>]
		[-d <pool/dataset>]

	where:
    	-h    Show this help text
    	-b    Perform a backup operation of dataset
    	-d    Destroy a given dataset, i.e. poolname/dataset
    	-r    Perform a restore operation from backup
    	-s    Source dataset from which we are cloning or backing-up
    	-t    Target dataset to which we are cloning or backing-up
    	-T    Test if lab environment already present, supply dataset name, i.e. poolname/dataset
    "

	echo "${usage}" >&2
}

while getopts "bd:rh?l:vs:t:T:" opt; do

    case "$opt" in
        h|\?)
            show_help
            exit 0
        ;;

        v)  verbose=1
        ;;

        l) ## Name of the lab environment, will be used as snapshot name
			lab_name="${OPTARG}"
		;;
        
        b) ## Backup to archive
			operation=backup
		;;

		d) ## Destroy a given dataset
			operation=destroy
			target_to="${OPTARG}"
		;;

		r) ## Restore from archive
			operation=restore
		;;

        s)	source_from="${OPTARG}"
			source_pool_name=${source_from%%\/*} # <= name of source pool, no slashes
			source_dataset_name=${source_from#*\/} # <= name of source dataset, minus pool
		;;

		t)	target_to="${OPTARG}"
			target_pool_name=${target_to%%\/*} # <= name of source pool, no slashes
			target_dataset_name=${target_to#*\/} # <= name of source dataset, minus pool
		;;

		T)	test_if_exist="${OPTARG}"
		;;
    esac
done

shift $((OPTIND-1))

[ "$1" = "--" ] && shift

function destroy_dataset() {

	local dataset_name=$1
	
	[[ "${debug}" -gt "0" ]] && set -x

	printf "[INFO] %s\n" "Removing dataset ${dataset_name}"
	/usr/sbin/zfs destroy -r "${dataset_name}"
	RET_CODE=$?

	[[ "${debug}" -gt "0" ]] && set +x

	return "${RET_CODE}"
}

function cleanup_zfs_destination() {
	##
	## Create snapshot of ZFS filesystem
	## Arguments required are:
	## 1st argument == name of dataset including name of pool
	## 2nd argument == name of snapshot to be created

	local dataset_name="$1"
	local snapshot_name="$2"
	local snapshot_name_on_dest=${dataset_name}/${source_dataset_name}@${snapshot_name}

	if [[ "${debug}" -gt "1" ]]; then

		echo /usr/sbin/zfs list -t snapshot "${dataset_name}@${snapshot_name}"
		echo /usr/sbin/zfs destroy -r "${snapshot_name_on_dest}"
		RET_CODE=0
	
	## If there is already a snapshot available at the destination, 
	## we are blowing it away, because we are assuming that it is stale.
	## Operation is not safe and we need to keep this in mind.

	else
		[[ "${debug}" -gt "0" ]] && set -x

		/usr/sbin/zfs list -t snapshot "${snapshot_name_on_dest}"

		if [[ $(/usr/sbin/zfs list -t snapshot "${snapshot_name_on_dest}") ]]; then
		
			printf "[INFO] %s\n" "Snapshot ${snapshot_name_on_dest} exists, removing."

			/usr/sbin/zfs destroy -r "${snapshot_name_on_dest}"
			RET_CODE=$?
		else
			## There is nothing to do if snapshot on destination does not exist
			RET_CODE=0
		fi

	fi

	[[ "${debug}" -gt "0" ]] && set +x
	return "${RET_CODE}"
}

function cleanup_zfs_destination_on_restore() {

	## This function will form a dataset path which we need to destroy
	## before we can do a restore from archive.
	##
	local dataset_name="$1"
	local snapshot_name="$2"
	local target_dataset_name=${source_from##*\/}
	local target_to_destroy=${dataset_name}/${target_dataset_name}

	[[ "${debug}" -gt "0" ]] && set -x

	if [[ $(/usr/sbin/zfs list -t snapshot "${target_to_destroy}@${snapshot_name}") ]]; then

		printf "[INFO] %s\n" "Destination ${target_to_destroy} is being destroyed"
		/usr/sbin/zfs destroy -r "${target_to_destroy}"
	
	fi

	[[ "${debug}" -gt "0" ]] && set -x	

	return "${RET_CODE}"
}

function create_zfs_snapshot() {
	##
	## Create snapshot of ZFS filesystem
	## Arguments required are:
	## 1st argument == name of dataset including name of pool
	## 2nd argument == name of snapshot to be created

	local dataset_name="$1"
	local snapshot_name="$2"

	if [[ "${debug}" -gt "1" ]]; then

		echo /usr/sbin/zfs snapshot -r "${dataset_name}@${snapshot_name}"
		echo /usr/sbin/zfs list -t snapshot "${dataset_name}@${snapshot_name}"
		RET_CODE=0
	
	else
		[[ "${debug}" -gt "0" ]] && set -x
		/usr/sbin/zfs snapshot -r "${dataset_name}@${snapshot_name}"
		RET_CODE=$?

		/usr/sbin/zfs list -t snapshot "${dataset_name}@${snapshot_name}"
	fi

	[[ "${debug}" -gt "0" ]] && set +x
	return $?
}

function send_zfs_snapshot() {

	function send_operation() {
		/usr/sbin/zfs send -R "${dataset_name}@${snapshot_name}" | zfs recv -Fduv "${target_name}"
		return $?
	}

	local dataset_name="$1"
	local snapshot_name="$2"
	local target_name="$3"

	if [[ "${debug}" -gt "1" ]]; then

		echo "/usr/sbin/zfs send -r "${dataset_name}@${snapshot_name}" | zfs recv -Fduv "${target_name}" "
	else
		[[ "${debug}" -gt "0" ]] && set -x
		
		## We need to make sure that we successfully sent our snapshot
		send_operation; recv_succeeded=$?
		[[ "${debug}" -gt "0" ]] && set +x
	fi

	## If the Send operation was successful, we need to do the following:
	## 1) List snapshot, to confirm that it was in fact created
	## 2) Remove snapshot from the source

	if [[ "${recv_succeeded}" -eq "0" ]]; then
		RET_CODE=0
	else
		printf "[ERROR] %s\n" "Failure sending snapshot to ${target_name}"
		RET_CODE=1
	fi
		
		printf "%s\n" "Cleaning-up snapshot ${dataset_name}@${snapshot_name}"

		[[ "${debug}" -gt "0" ]] && set -x
		/usr/sbin/zfs destroy -r "${dataset_name}@${snapshot_name}"

		## Do not enable below during testing. At some point we will want to
		## remove the actual dataset on the source.
		##
		## /usr/sbin/zfs destroy -r "${dataset_name}"


	[[ "${debug}" -gt "0" ]] && set +x
	return "${RET_CODE}"	
}

function restore_zfs_snapshot() {

	function send_operation() {
		/usr/sbin/zfs send -R "${source_pool_name}/${source_dataset_name}@${snapshot_name}" | zfs recv -Feuv "${target_name}"
		return $?
	}

	local dataset_name="$1"
	local snapshot_name="$2"
	local target_name="$3"

	if [[ "${debug}" -gt "1" ]]; then

		echo "/usr/sbin/zfs send -r "${dataset_name}@${snapshot_name}" | zfs recv -Feuv "${target_name}" "
	else
		[[ "${debug}" -gt "0" ]] && set -x
		
		## We need to make sure that we successfully sent our snapshot
		send_operation; recv_succeeded=$?
		[[ "${debug}" -gt "0" ]] && set +x
	fi

	## If the Send operation was successful, we need to do the following:
	## 1) List snapshot, to confirm that it was in fact created
	## 2) Remove snapshot from the source

	if [[ "${recv_succeeded}" -eq "0" ]]; then
		RET_CODE=0
	else
		printf "[ERROR] %s\n" "Failure sending snapshot to ${target_name}"
		RET_CODE=1
	fi
		
		printf "%s\n" "Cleaning-up snapshot ${dataset_name}@${snapshot_name}"

		# [[ "${debug}" -gt "0" ]] && set -x
		# /usr/sbin/zfs destroy -r "${dataset_name}@${snapshot_name}"

		## Do not enable below during testing. At some point we will want to
		## remove the actual dataset on the source.
		##
		## /usr/sbin/zfs destroy -r "${dataset_name}"


	[[ "${debug}" -gt "0" ]] && set +x
	return "${RET_CODE}"	
}

function mount_zfs_after_restore() {

	## Enable NFS share on the dataset being restored
	##
	function enable_nfs_share() {

		local dataset_to_share=$1

		/usr/sbin/zfs set sharenfs="anon=-1,sec=sys,rw=*,root=@10.0.0.0/8" "${dataset_to_share}"
		RET_CODE=$?
	}
	
	local target_name="$1"
	local source_dataset_name=${source_from##*\/}

	[[ "${debug}" -gt "0" ]] && set -x	

	/usr/sbin/zfs mount "${target_name}/${source_dataset_name}"
	enable_nfs_share "${target_name}/${source_dataset_name}"
	
	[[ "${debug}" -gt "0" ]] && set +x

	return "${RET_CODE}"
}
## Quick sanity checks to make sure we have required elements
##


if [[ ! -z "${test_if_exist}" ]]; then
	
	if [[  $(zfs list -H -oname "${test_if_exist}" ) ]]; then
		RET_CODE=0
	else
		RET_CODE=1
	fi
	
	exit "${RET_CODE}"
fi

if [[ "${operation}" == "destroy" ]]; then

	destroy_dataset "${target_to}"; RET_CODE=$?
	exit "${RET_CODE}"
fi

if [[ -z "${source_from}" ]]; then 
	printf "[ERROR] %s\n" "Source was not given; however, it is required!";
	cannot_continue=1
fi

if [[ -z "${target_to}" ]] ; then
	printf "[ERROR] %s\n" "Target was not given; however, it is required!";
	cannot_continue=1
fi

if [[ -z "${operation}" ]]; then
	printf "[ERROR] %s\n" "Operation to perform not given; however, it is required!";
	cannot_continue=1
fi

if [[ "${cannot_continue}" -eq "1" ]]; then
	printf "%s\n" ""
	show_help
	exit 1
fi

## Set default lab name if one was not supplied
##
if [[ -z "${lab_name}" ]]; then
	lab_name=latest
fi


## Main body of the script ##

if [[ "${operation}" == "backup" ]]; then

	cleanup_zfs_destination "${target_to}" "${lab_name}"; RET_CODE=$?

	[[ "${RET_CODE}" -eq "1" ]] && (printf "[ERROR] %s\n" "Something happened during clean-up."; exit 1)

	## Create snapshot on <poolname>/<datasetname>
	create_zfs_snapshot "${source_from}" "${lab_name}"

	## Send snapshot to another dataset for safe keeping
	send_zfs_snapshot "${source_from}" "${lab_name}" "${target_to}"
	exit $?
fi

if [[ "${operation}" == "restore" ]]; then

	#cleanup_zfs_destination_on_restore "${target_to}" "${lab_name}"; RET_CODE=$?
	restore_zfs_snapshot "${source_from}" "${lab_name}" "${target_to}"
	mount_zfs_after_restore "${target_to}"
	exit $?
fi


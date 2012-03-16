#!/usr/bin/bash
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
# 
# Copyright 2012 Nexenta Systems, Inc.  All rights reserved.
# Use is subject to license terms.
#
# Written by Sam Zaydel
#
# Purpose of the script is quite simple. We want to stress test disks and 
# need a meaningful way to do it before a system is rolled out.
# At the moment other tools are primarily designed to do performance
# testing v. a burn-in test and all we need is a way of stressing disks.
# We are using xargs and pushing a list of all disks in the the array we
# build from /dev/rdsk/* devices, which is quite dumb at the moment and 
# does not distinguish between syspool and ssds, etc, but it is an OK
# start. Once we have this worked out and ready to introduce writes we will
# have to be far more careful about what disks we are writing to.
# Needed to add a trap to make sure that we are not running dd's out of
# control after leaving the script.

scriptname=$0 # First argument is shell command (as in C)
total_args=$#  # Number of args, not counting $0

## Force a command line argument, if none supplied we drop out.
if [ "${total_args}" -eq 0 ]; then
    printf "[%s] %s\n" "${scriptname}" "could not start due to a missing required argument."
    printf "%s\n" "Error: Please enter minimum number of minutes to run the test."
    exit 1
fi
    
debug=1  ## Debug flag is enabled while testing to prevent anything stupid
flag=~/stopdd.flag  ## This flag may be useful if we need to abort prematurely
date_cmd=/usr/bin/date
dd_cmd=/usr/bin/dd
##awk_cmd=/usr/bin/awk
##sed_cmd=/usr/bin/sed
##sort_cmd=/usr/bin/sort
rm_cmd=/usr/bin/rm
grep_cmd=/usr/bin/grep
egrep_cmd=/usr/bin/egrep
xargs_cmd=/usr/bin/xargs
basename_cmd=/usr/bin/basename
devfs_cmd=/usr/sbin/devfsadm
pkill_cmd=/usr/bin/pkill
zpool_cmd=/usr/sbin/zpool
is_syspool=''   ## Variable is used in the case statement to validate syspool
rd_counter=0
wr_counter=0
minutes=${1}
seconds=$(( ${minutes} * 60 ))

function linesep ()
{
## Print a line separator 80-characters long
printf "%80s\n" | ${TR} ' ' '='
}

function newline ()
{
printf "%s\n"
}

function cleanup () {
    ${rm_cmd} -f ${flag}
    return 0
}

function validate_syspool () {

    ## Return state of syspool, which should contain list of disks.
    newline
    ${zpool_cmd} status syspool

    while [ -z "${is_syspool}" ]
        do
            newline
            printf "%s\n%s\n" "[CRIT] Please confirm that these disks are your syspool." "${syspool[@]}"
            newline
            printf "%s" "Continue, or stop? [Y|N] "; read is_syspool
            newline

            case ${is_syspool} in

                Y|y ) ## We are good to go here and are returning 0
                    return 0
                    ;;

                * ) ## Anything other than Y|y is not expected, bailing
                    printf "%s\n" "[CRIT] Something must be wrong. Exiting."
                    return 1
                    ;;
            esac
        done
}

## We do not want any rogue dd's going on, so need to trap them and cleanup.
##
trap 'printf "\n%s\n" "[WARN] Signal trapped. Cleaning-up."; \
touch ${flag}; ${pkill_cmd} dd; pkill ${scriptname}; echo Last Return Code: $?' 1 2 3 15

## Just so we have some sense of what is being cleaned-up, we want to collect
## device links that are being removed.
##
dev_cleanup_log=/tmp/devfsadm-$(hostname)-$(${date_cmd} +%s).log


## This is our syspool array and should only contain syspool disks
##
syspool=( $(zpool status syspool|awk '/c[0-9]+t[0-9]+d[0-9]+/ {print $1}') )

## only basenames are included in the array `/dev/rdsk` is stripped to reduce
## size of non-unique argument components in the array.
##
    ## This is run if the debug flag is set and we are testing the functionality
    if [[ ${debug} -eq 1 ]]; then
        ## Please, add at least one disk from syspool to this array to make
        ## sure that in fact we are correctly excluding the disk(s).
        ## In the example below first disk in list is a syspool disk.
        ##
        arr_disks=( c1t0d0s0 c1t10d0s0 c1t11d0s0 )

        echo "[DEBUG] Before Array change: ${arr_disks[@]}"
        ## We adjust the final array to not include any disks in syspool
        for disk in "${syspool[@]}"; do 
            arr_disks=( ${arr_disks[@]//${disk}*/} )
        done
        echo "[DEBUG] After Array change: ${arr_disks[@]}"

        arr_disk_len=${#arr_disks[@]}       ## This many disk entries in the array

    ## This is run if the debug flag is not set, basically production
    else
        arr_disks=( $(ls /dev/rdsk/*s0|${xargs_cmd} -n1 ${basename_cmd}) )

        ## We adjust the final array to not include any disks in syspool
        for disk in "${syspool[@]}"; do 
            arr_disks=( ${arr_disks[@]//${disk}*/} )
        done

        arr_disk_len=${#arr_disks[@]}       ## This many disk entries in the array
    fi

## We validate that in fact the disks that we think are in syspool
## are indeed in the syspool, if not matched, we exit.
##
validate_syspool || exit $?

## If we fail above, there is no sense in defining any more functions below.
## Purely for performance reasons we are not creating the below functions.

## Lets clean-up the device links to make sure that we are not reading
## stale links and observing errors from `dd`.
##
function clean_dev_links() {
    ${devfs_cmd} -Cv > ${dev_cleanup_log} 2>&1; ret_code=$?
    return ${ret_code}
}

## This is our read test function, it is incomplete as hell
## for now, but should suffice as a first shot at this.
##
function run_read_test() {
    local fn=${FUNCNAME}
    local rrt_count=${1}

    if [[ ${debug} -eq 1 ]]; then
        ## If in debug mode, lets make for a much smaller test
        local dd_args="bs=128k iflag=sync count=100"
    else
        local dd_args="bs=128k iflag=sync"
    fi
    ## local dd_args="bs=128k oflag=sync"
    ## Choosing this option over the second option commented out below
    ## to avoid using `tr` unnecessarily, but leaving in as a option.
    printf "[INFO] Test [%s] Started. Function %s entered.\n[INFO] Arguments to [ dd ] are: %s\n\n" "${rrt_count}" "${fn}" "${dd_args}"
    for disk in "${arr_disks[@]}"; do echo ${disk}; done | xargs -n1 -i -t -P${arr_disk_len} ${dd_cmd} if=/dev/rdsk/{} of=/dev/null ${dd_args}
    printf "### Test [%s] Stopped. Leaving function %s. ###\n\n" "${rrt_count}" "${fn}"
    ##opt 2
    # echo "${myarr[@]}"|tr ' ' '\n' | xargs -n1 -i -t -P10 echo dd if=/dev/rdsk/{} of=/dev/null bs=1k count=4
    return 0
}

function run_write_test() {
    local fn=${FUNCNAME}
    local wwt_count=${1}

    if [[ ${debug} -eq 1 ]]; then
        ## If in debug mode, lets make for a much smaller test
        local dd_args="bs=128k oflag=sync count=100"
    else
        local dd_args="bs=128k oflag=sync"
    fi
    ## local dd_args="bs=128k oflag=sync"
    ## Choosing this option over the second option commented out below
    ## to avoid using `tr` unnecessarily, but leaving in as a option.
    printf "[INFO] Test [%s] Started. Function %s entered.\n[INFO] Arguments to [ dd ] are: %s\n\n" "${wwt_count}" "${fn}" "${dd_args}"
    for disk in "${arr_disks[@]}"; do echo ${disk}; done | xargs -n1 -i -t -P${arr_disk_len} ${dd_cmd} if=/dev/urandom of=/dev/rdsk/{} ${dd_args}
    printf "### Test [%s] Stopped. Leaving function %s. ###\n\n" "${wwt_count}" "${fn}"
    ##opt 2
    # echo "${myarr[@]}"|tr ' ' '\n' | xargs -n1 -i -t -P10 echo dd if=/dev/rdsk/{} of=/dev/null bs=1k count=4
    return 0
}

## If there is still an old flag in place that was used to stop
## the test prematurely we need to clean it up first.
if [[ -f ${flag} ]]; then

    printf "\nRemoving old flag that was seemingly left over. >>> %s\n\n" "${flag}"
    cleanup
fi

## Let's clean-up stale device links and exit before anything else happens
## if for some reason we get anything other than `0` as return from function.
##
clean_dev_links || exit 1

## Set our start time here. We need to know when we started to make
## the rest of the math work.
##
start_t=$(${date_cmd} +%s)

## For the moment we are conservative and only doing a read test,
## as an example of what we can do, if sufficient, we will add
## write test to this script, which will be destructive.
##
while [[ $(( ${start_t} + ${seconds} )) > $(${date_cmd} +%s) && ! -f ${flag} ]]; do

    while [[ ! -f ${flag} ]]; do
        rd_counter=$(( rd_counter + 1 ))
        run_read_test ${rd_counter} 
    done

    while [[ ! -f ${flag} ]]; do    
        wr_counter=$(( wr_counter + 1 ))
        run_write_test ${wr_counter}
    done
done

if [[ -f ${flag} ]]; then
    printf "[INFO] Flag file %s indicting premature termination was detected." "${flag}" 
fi

## Got this far, means we are done and time to exit
printf "\n[INFO] Script ${scriptname} finished.\n[INFO] Time Elapsed: %s Number of Read tests: %s\n" " $(( $(${date_cmd} +%s) - ${start_t} ))" "${rd_counter}"

## Will need to add some exit criteria later, for the moment this will do.
exit 0

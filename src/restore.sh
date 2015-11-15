#!/bin/bash
# Restore database and other files
#   You need to install uuidgen, xtrabackup, qpress
#
# Author: Yunhui Fu <yhfudev@gmail.com>
# License: MIT
#############################################################################
my_getpath () {
    PARAM_DN="$1"
    shift
    #readlink -f
    DN="${PARAM_DN}"
    FN=
    if [ ! -d "${DN}" ]; then
        FN=$(basename "${DN}")
        DN=$(dirname "${DN}")
    fi
    DNORIG=$(pwd)
    cd "${DN}" > /dev/null 2>&1
    DN=$(pwd)
    cd "${DNORIG}"
    if [ "${FN}" = "" ]; then
        echo "${DN}"
    else
        echo "${DN}/${FN}"
    fi
}
DN_EXEC=$(dirname $(my_getpath "$0") )
if [ ! "${DN_EXEC}" = "" ]; then
    DN_EXEC="$(my_getpath "${DN_EXEC}")/"
else
    DN_EXEC="${DN_EXEC}/"
fi
DN_TOP="$(my_getpath "${DN_EXEC}/../")"
DN_EXEC="$(my_getpath "${DN_TOP}/src/")"
#####################################################################
if [ -f "${DN_EXEC}/libconfig.sh" ]; then
. ${DN_EXEC}/libbash.sh
. ${DN_EXEC}/libconfig.sh
. ${DN_EXEC}/libbackup.sh
fi

mr_trace () {
    echo "$(date +"%Y-%m-%d %H:%M:%S,%N" | cut -c1-23) [self=${BASHPID},$(basename $0)] $@" 1>&2
}

EXEC_MYSQL="$(which mysql)"
EXEC_MYSQLDUMP="$(which mysqldump)"

FN_CONF="${DN_TOP}/backup.conf"

#############################################################################
restore_all ()
{
    IFS=',' read -r -a baklst <<< "$BAK_LIST"
    mr_trace "# of baklst " ${#baklst[*]}
    CUR=0
    while (( $CUR < ${#baklst[*]} )) ; do
        lst=(${baklst[$CUR]})
        #mr_trace "lst item=" ${baklst[$CUR]}
        #mr_trace "lst4=" ${lst[4]}
        CUR=$(( $CUR + 1 ))
        if [[ ${lst[4]} == "/etc"* ]] ; then
            echo "We suggest you to pick some files to edit and then recover it to /etc/" 1>&2
            echo "other than over write it directly, which may cause system unusable/unreachable." 1>&2
            echo "" 1>&2
            echo -n "Are you sure to over write the /etc/ folder with backup files? [y/N] " 1>&2
            read A
            if [[ "" = "$A" || "n" = "$A" || "N" = "$A" ]] ; then
                mr_trace "Skiping ${lst[4]} ..."
                continue
            fi
        fi

        restore_api ${lst[3]} ${lst[1]} ${lst[0]} "${FN_CONF}" "${DATETIME}" ${lst[4]} ;
    done
}

if [ ! "$1" = "" ]; then
FN_CONF="$1"
fi

read_config_file "${FN_CONF}"

restore_all

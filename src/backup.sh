#!/bin/bash
# Backup database and other files
#   You need to install uuidgen, xtrabackup, qpress
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
cron_backup ()
{
    # the callback function
    local PARAM_CB_BACKUP=$1
    shift
    local PARAM_CB_HASFULL=$1
    shift
    local PARAM_CB_DATA=$@
    shift

    BACKUP_POLICY=${TYPEBAKPOLICY_INCR}
    # 1. calculate the backup type
    # if no full backup, then full backup
    if [ $(${PARAM_CB_HASFULL} ${PARAM_CB_DATA}) = 0 ] ; then
        mr_trace "Warning: not found full backup files for ${PARAM_CB_BACKUP}, create one ..."
        BACKUP_POLICY=${TYPEBAKPOLICY_FULL}
    else
        if [ "${DATETIME:6:2}" = "01" ] ; then
            # the first day of a month
            BACKUP_POLICY=${TYPEBAKPOLICY_FULL}
        else
            # get the week day
            if [ "${WEEKDAY}" = "7" ]; then
                # if Sunday, then diff backup
                BACKUP_POLICY=${TYPEBAKPOLICY_DIFF}
            else
                # if others
                BACKUP_POLICY=${TYPEBAKPOLICY_INCR}
            fi
        fi
    fi

    ${PARAM_CB_BACKUP} ${BACKUP_POLICY} ${PARAM_CB_DATA}
    return 0
}

have_full_backup_files ()
{
    local NAME=$1
    shift
    local TYPE=$1
    shift
    local CB_BAK=$1
    shift

    FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${NAME}" "*" "${FNH_FULL}")
    FN_FULL=$(find_file_latest "${TYPE}" "${DN_BAK}" "${FN_MASK}" "" "${DATETIME}")
    #mr_trace "have_full_backup_files: FN_FULL=$FN_FULL"
    lst_full=($FN_FULL)
    #mr_trace "# of full: ${#lst_full[*]}"
    if (( ${#lst_full[*]} < 1 )) ; then
        echo "0"
    else
        echo "1"
    fi
}

backup_files ()
{
    local PARAM_BAKPOLICY=$1
    shift
    local NAME=$1
    shift
    local TYPE=$1
    shift
    local CB_BAK=$1
    shift
    local MYDATADIR=$1
    shift

    backup_api ${CB_BAK} "${TYPE}" "${PARAM_BAKPOLICY}" "${NAME}" "${FN_CONF}" "${MYDATADIR}" "${DN_BAK}"

    case ${BACKUP_POLICY} in
    ${TYPEBAKPOLICY_FULL}) # 全备份
        mr_trace "remove all of the full earler than this one"
        FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${NAME}" "*" "*")
        find "${DN_BAK}" -maxdepth 1 -type "${TYPE}" -name "${FN_MASK}" \
            | awk -v TM=${DATETIME} -F_ '{if ($3 < TM) {print $0;} }' \
            | xargs -n 1 rm -rf
        ;;

    ${TYPEBAKPOLICY_DIFF}) # 差异备份
        mr_trace "delete the file between full and diff"
        FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${NAME}" "*" "${FNH_FULL}")
        FN_FULL=$(find_file_latest "${TYPE}" "${DN_BAK}" "${FN_MASK}" "" "${DATETIME}")
        lst_full=($FN_FULL)
        if (( ${#lst_full[*]} == 1 )) ; then
            TMS=$(echo ${FN_FULL} | awk -F_ '{print $3}')
            FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${NAME}" "*" "*")
            mr_trace "time=($TMS,${DATETIME}), fnmask=${FN_MASK}"
            find "${DN_BAK}" -maxdepth 1 -type "${TYPE}" -name "${FN_MASK}" \
                | awk -v TMS=${TMS} -v TME=${DATETIME} -F_ '{if ((TMS < $3) && ($3 < TME)) {print $0;} }' \
                | xargs -n 1 rm -rf
        fi
        ;;

    ${TYPEBAKPOLICY_INCR}) # 增量备份
        mr_trace "process the incr dir"
        ;;

    *)
        mr_trace "Error in argument backup type"
        return 1
        ;;
    esac
}

BAK_LIST0=(
    #"mysql     d backupcb_mysql restorecb_mysql /var/lib/mysql"
    "mysql     d backupcb_mysql restorecb_mysql /usr/local/mysql/var/"
    "confetc   f backupcb_files restorecb_files /etc/"
    "filecerts f backupcb_files restorecb_files /home/cert/"
    "filewww   f backupcb_files restorecb_files /home/wwwroot/"
    "confnginx f backupcb_files restorecb_files /usr/local/nginx/conf/"
    "confphp   f backupcb_files restorecb_files /usr/local/php/etc/"
    )

restore_all ()
{
    echo ${BAK_LIST} | awk -F, '{for (i = 1; i <= NF; i ++) print $i;}' | while read N T B R D; do \
        mr_trace "settings: $N $T $B $R $D";
        restore_api $R $T $N "${FN_CONF}" "${DATETIME}" $D;
    done
}

cron_backup_all0 ()
{
    CUR=0
    while (( $CUR < ${#BAK_LIST0[*]} )) ; do
        lst=(${BAK_LIST[$CUR]})
        CUR=$(( $CUR + 1 ))
        cron_backup backup_files have_full_backup_files ${lst[0]} ${lst[1]} ${lst[2]} ${lst[4]}
    done
}

cron_backup_all ()
{
    echo ${BAK_LIST} | awk -F, '{for (i = 1; i <= NF; i ++) print $i;}' | while read N T B R D; do \
        mr_trace "settings: $N $T $B $R $D";
        cron_backup backup_files have_full_backup_files $N $T $B $D;
    done
}

# test:
cron_backup_test ()
{
    cron_backup backup_files have_full_backup_files "fileetc f backupcb_files /etc/"
}

test_cron_bakall ()
{
if [ 0 = 1 ]; then
    mr_trace "none"

    DATETIME=20150923
    WEEKDAY=5
    cron_backup_test

    DATETIME=20150924
    WEEKDAY=6
    cron_backup_test

    DATETIME=20150925
    WEEKDAY=7
    cron_backup_test

    DATETIME=20150926
    WEEKDAY=1
    cron_backup_test

    DATETIME=20150927
    WEEKDAY=2
    cron_backup_test


    DATETIME=20151001
    WEEKDAY=4
    cron_backup_test

    DATETIME=20151002
    WEEKDAY=5
    cron_backup_test

    DATETIME=20151003
    WEEKDAY=6
    cron_backup_test

    DATETIME=20151004
    WEEKDAY=7
    cron_backup_test

    DATETIME=20151005
    WEEKDAY=1
    cron_backup_test
fi

    DATETIME=20151011
    WEEKDAY=7
    cron_backup_test

    DATETIME=20151012
    WEEKDAY=1
    cron_backup_test

    DATETIME=20151013
    WEEKDAY=2
    cron_backup_test

    DATETIME=20151018
    WEEKDAY=7
    cron_backup_test

    DATETIME=20151025
    WEEKDAY=7
    cron_backup_test

if [ 0 = 1 ]; then
    DATETIME=20151101
    WEEKDAY=7
    cron_backup_test

    DATETIME=20151102
    WEEKDAY=1
    cron_backup_test

    DATETIME=20151108
    WEEKDAY=7
    cron_backup_test
fi
}
#test_cron_bakall

if [ ! "$1" = "" ]; then
FN_CONF="$1"
fi

EMAIL_ADMIN="youraccount@gmail.com"

read_config_file "${FN_CONF}"

mkdir -p "${DN_BAK}"

detect_status ()
{
    RET=$(netstat -nl | awk 'NR>2{if ($4 ~ /.*:3306/) {print "1";exit 0}}')
    if [ "$RET" = "1" ]; then
        #RET2=$(mysql -u ${DB_USER} -p${DB_PW} -e"show slave status\G" | grep "Running" | awk '{if ($2 != "Yes") {print "0";exit 1}}')
        #if [ "$RET2" = "0" ]; then
        #    mr_trace "Error in slave"
        #    [ ! -f "/tmp/dbflg-slave" ] && echo "Slave is not working!" | mail -s "Warn!MySQL Slave is not working" ${EMAIL_ADMIN}
        #else
        #    [ -f "/tmp/dbflg-slave" ] && rm -f /tmp/dbflg-slave
        #fi
        [ -f "/tmp/dbflg-down" ] && rm -f /tmp/dbflg-down
    else
        [ ! -f "/tmp/dbflg-down" ] && echo "Mysql Server is down!" | mail -s "Warn!MySQL server is down!" ${EMAIL_ADMIN}
        touch /tmp/dbflg-down
    fi
}

detect_status
cron_backup_all

chown -R backupper:users "${DN_BAK}"

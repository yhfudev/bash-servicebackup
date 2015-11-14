#!/bin/bash
# Backup database
#   前提要求：安装了 uuidgen, xtrabackup, qpress
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

mr_trace () {
    echo "$(date +"%Y-%m-%d %H:%M:%S,%N" | cut -c1-23) [self=${BASHPID},$(basename $0)] $@" 1>&2
}

EXEC_MYSQL="$(which mysql)"
EXEC_MYSQLDUMP="$(which mysqldump)"

FN_CONF="${DN_TOP}/backup.conf"

#############################################################################
# 备份函数定义：
#   每个类型的函数需要提供以下几个参数：1) 为什么备份策略；2) 打包备份文件存放路径； 3) 文件名; 4) 其他参数，一般为用户名密码之类

# 备份策略类型:
TYPEBAKPOLICY_FULL=1
TYPEBAKPOLICY_DIFF=2
TYPEBAKPOLICY_INCR=3
TYPEBAKPOLICY_RESTORE=4 # only used in restore for last step

# 备份文件的前缀后缀
FNH_PREFIX=backup
FNH_FULL="0full" # 全备份
FNH_DIFF="1diff" # 差异备份
FNH_INCR="2incr" # 增量备份

# 本次备份时间，用于附加到备份文件名中
#DATETIME=`date -u +%Y%m%d%H%M%S`
DATETIME=`date +%Y%m%d%H%M%S`
WEEKDAY=$(date +%u)
#############################################################################

file_prefix_backup () {
    echo "${1}_${2}_${3}_${4}"
}

# 查找时间区域内所有的备份目录, 如果一端时间置空，则从另一端开始查找第一个符合的
# 参数1: 查找文件类型：f 普通文件，d 路径
# 参数1: 备份文件存放路径
# 参数2: 备份文件名的前缀
# 参数3: 查找起始时间,格式为 19790101000000
# 参数4: 查找结束时间,格式为 19790101000000
find_file_latest () {
    local ARG_FLF_TYPE=$1
    shift
    local ARG_FLF_BAKDN=$1
    shift
    local ARG_FLF_FNHEAD=$1
    shift
    local ARG_FLF_TIMESTART=$1
    shift
    local ARG_FLF_TIMEEND=$1
    shift

    mr_trace "find_bakdn_latest(bakdn=${ARG_FLF_BAKDN}, fnhead=${ARG_FLF_FNHEAD}, tmstart=${ARG_FLF_TIMESTART}, tmend=${ARG_FLF_TIMEEND}"

    local TM_START=${ARG_FLF_TIMESTART}
    if [ "${ARG_FLF_TIMESTART}" = "" ]; then
        TM_START=0
    fi

    local TM_END=${ARG_FLF_TIMEEND}
    if [ "${ARG_FLF_TIMEEND}" = "" ]; then
        TM_END=0
    fi

    TMP_FIND_PARAM="-maxdepth 1 -type ${ARG_FLF_TYPE}"
    if [ "${ARG_FLF_TIMESTART}" = "" ]; then
        ARG_SORT="-r"
    fi
    mr_trace "find ${ARG_FLF_BAKDN} ${TMP_FIND_PARAM} -name '${ARG_FLF_FNHEAD}*' PIPE sort ${ARG_SORT} PIPE awk -F_ -v TMSTART=${TM_START} -v TMEND=${TM_END}"
    find ${ARG_FLF_BAKDN} ${TMP_FIND_PARAM} -name "${ARG_FLF_FNHEAD}*" \
        | sort ${ARG_SORT} \
        | awk -F_ -v TMSTART=${TM_START} -v TMEND=${TM_END} \
            'BEGIN{ret=""; flg=0; tms=0+TMSTART; tme=0+TMEND; if (tms==0) flg=1; if (tme==0) flg=1;}{val=0+$3; if (flg == 1) { if (ret == "") {if (tms > 0 && val >= tms) {ret=$0;} if (tme > 0 && val <= tme) {ret=$0;} } } else {if ((tms <= val) && (val <= tme)) {ret=ret " " $0;} } }END{print ret;}'

# 'BEGIN{ret=""; flg=0; tms=0+TMSTART; tme=0+TMEND; if (tms==0) flg=1; if (tme==0) flg=1;}{val=0+$3; if (flg == 1) { if (ret == "") {if (tms > 0 && val >= tms) {print "ret 1 = " ret; ret=$0;} if (tme > 0 && val <= tme) {print "ret 2 = " ret; ret=$0;} } } else {if ((tms <= val) && (val <= tme)) {print "tm=" val ", tms=" tms ", tme=" tme ", ret 3 += " $0; ret=ret " " $0;} } }END{print ret;}'
}

# 查找时间区域内所有的备份目录, 如果一端时间置空，则从另一端开始查找第一个符合的
# 参数1: 备份文件存放路径
# 参数2: 备份文件名
# 参数3: 查找起始时间,格式为 19790101000000
# 参数4: 查找结束时间,格式为 19790101000000
find_bakdn_latest () {
    find_file_latest "d" "$1" "$2" "$3" "$4"
}

# 查找时间区域内所有的备份文件, 如果一端时间置空，则从另一端开始查找第一个符合的
# 参数1: 备份文件存放路径
# 参数2: 备份文件名
# 参数3: 查找起始时间,格式为 19790101000000
# 参数4: 查找结束时间,格式为 19790101000000
find_bakfn_latest () {
    find_file_latest "f" "$1" "$2" "$3" "$4"
}

backupcb_files ()
{
    # the policy: full, diff, or incremental
    local PARAM_BAKPOLICY=$1
    shift
    # the config file
    local PARAM_CONFIG=$1
    shift
    # the file prefix
    local PARAM_FN_PREFIX=$1
    shift
    # the directory to be saved
    local PARAM_DN_SAVE=$1
    shift
    # the previous backup directory, for diff and incremental
    local PARAM_DN_PREVIOUS=$1
    shift

    case ${PARAM_BAKPOLICY} in
    ${TYPEBAKPOLICY_FULL}) # 全备份
        mr_trace tar -C ${PARAM_DN_SAVE} -czf ${PARAM_FN_PREFIX}.tar.gz .
        tar -C ${PARAM_DN_SAVE} -czf ${PARAM_FN_PREFIX}.tar.gz . #2>/dev/null
        ;;

    ${TYPEBAKPOLICY_DIFF}) # 差异备份
        if [ ! -f "${PARAM_DN_PREVIOUS}" ]; then
            mr_trace "Error: not exist dir: ${PARAM_DN_PREVIOUS}"
            return -1
        fi
        # get the date
        DAT=$(echo ${PARAM_DN_PREVIOUS} | awk -F_ '{print $3}')
        mr_trace tar -N ${DAT:0:8} -C "${PARAM_DN_SAVE}" -czf "${PARAM_FN_PREFIX}.tar.gz" .
        tar -N ${DAT:0:8} -C "${PARAM_DN_SAVE}" -czf "${PARAM_FN_PREFIX}.tar.gz" . #2>/dev/null
        ;;

    ${TYPEBAKPOLICY_INCR}) # 增量备份
        if [ ! -f "${PARAM_DN_PREVIOUS}" ]; then
            mr_trace "Error: not exist dir: ${PARAM_DN_PREVIOUS}"
            return -1
        fi
        # get the date
        DAT=$(echo ${PARAM_DN_PREVIOUS} | awk -F_ '{print $3}')
        mr_trace tar -N ${DAT:0:8} -C "${PARAM_DN_SAVE}" -czf "${PARAM_FN_PREFIX}.tar.gz" .
        tar -N ${DAT:0:8} -C "${PARAM_DN_SAVE}" -czf "${PARAM_FN_PREFIX}.tar.gz" . #2>/dev/null
        ;;

    *)
        mr_trace "Error in argument backup type"
        return 1
        ;;
    esac
    return 0
}

backupcb_mysql ()
{
    # the policy: full, diff, or incremental
    local PARAM_BAKPOLICY=$1
    shift
    # the config file
    local PARAM_CONFIG=$1
    shift
    # the file prefix
    local PARAM_DN_BASE=$1
    shift
    # the directory to be saved, for mysql is /var/lib/mysql/
    local PARAM_DN_SAVE=$1
    shift
    # the previous backup directory, for diff and incremental
    local PARAM_DN_PREVIOUS=$1
    shift

    mr_trace "PARAM_DN_BASE=$PARAM_DN_BASE"
    read_config_file "${PARAM_CONFIG}"

    local OPTOTHER=
    if [ ! "${DB_CONF}" = "" ]; then
        # --defaults-file has to be the first argument
        OPTOTHER="--defaults-file=${DB_CONF}"
    fi
    if [ ! "${DB_LIST}" = "" ]; then
        OPTOTHER="${OPTOTHER} --include=\"${DB_LIST}\""
    fi
    if [ ! "${DB_HOST}" = "" ]; then
        OPTOTHER="${OPTOTHER} --host=${DB_HOST}"
    fi
    if [ ! "${DB_PORT}" = "" ]; then
        OPTOTHER="${OPTOTHER} --port=${DB_PORT}"
    fi
    if [ ! "${DB_USER}" = "" ]; then
        OPTOTHER="${OPTOTHER} --user=${DB_USER}"
    fi
    if [ ! "${DB_PW}" = "" ]; then
        OPTOTHER="${OPTOTHER} --password=${DB_PW}"
    fi
    OPTOTHER="${OPTOTHER} --no-timestamp"
    OPTOTHER="${OPTOTHER} --compress"

    case ${PARAM_BAKPOLICY} in
    ${TYPEBAKPOLICY_FULL}) # 全备份
        DBN_ALL=$(echo "SHOW DATABASES;" | mysql -u ${DB_USER} -p${DB_PW})
        mr_trace "dump all: ${DBN_ALL}"
        for TMP_DB in ${DBN_ALL}; do
            ${EXEC_DUMPDB} --hex-blob --opt ${TMP_DB} | gzip -9 > "sqlgz-${PARAM_DN_BASE}/${TMP_DB}.gz"
        done

        mr_trace innobackupex ${OPTOTHER} ${PARAM_DN_BASE}
        innobackupex ${OPTOTHER} ${PARAM_DN_BASE}
        ;;

    ${TYPEBAKPOLICY_DIFF}) # 差异备份
        if [ ! -d "${PARAM_DN_PREVIOUS}" ]; then
            mr_trace "Error: not exist dir: ${PARAM_DN_PREVIOUS}"
            return -1
        fi
        mr_trace innobackupex ${OPTOTHER} --incremental-basedir="${PARAM_DN_PREVIOUS}" --incremental "${PARAM_DN_BASE}"
        innobackupex ${OPTOTHER} --incremental-basedir="${PARAM_DN_PREVIOUS}" --incremental "${PARAM_DN_BASE}"
        ;;

    ${TYPEBAKPOLICY_INCR}) # 增量备份
        if [ ! -d "${PARAM_DN_PREVIOUS}" ]; then
            mr_trace "Error: not exist dir: ${PARAM_DN_PREVIOUS}"
            return -1
        fi
        mr_trace innobackupex ${OPTOTHER} --incremental-basedir="${PARAM_DN_PREVIOUS}" --incremental "${PARAM_DN_BASE}"
        innobackupex ${OPTOTHER} --incremental-basedir="${PARAM_DN_PREVIOUS}" --incremental "${PARAM_DN_BASE}"
        ;;

    *)
        mr_trace "Error in argument backup type"
        return 1
        ;;
    esac
    return 0
}

#############################################################################
# 备份普通文件
# 参数0: 回调函数
# 参数1: 备份策略，全备份 (1)、差异备份 (2)、增量备份 (3)
# 参数2: 备份名字
# 参数3: 配置文件
# 参数4: 需要备份的文件路径
# 参数5: 备份文件存放路径
# example: backup_api "full" "etc" "backup.conf" "/etc" "/backup"
backup_api () {
    # the callback function
    local PARAM_CALLBACK=$1
    shift
    # the type of backup file(f)/dir(d)
    local PARAM_TYPE=$1
    shift
    local PARAM_BAKPOLICY=$1
    shift
    local PARAM_NAME=$1
    shift
    # the config file
    local PARAM_CONFIG=$1
    shift
    # the dir to be backup
    local ARG_BMS_DNSAVE=$1
    shift
    # the dir to store the backup file
    local ARG_BMS_BAKDN=$1
    shift

    #read_config_file "${PARAM_CONFIG}"

    local FN_PREFIX=$(file_prefix_backup "${FNH_PREFIX}" "${PARAM_NAME}" "${DATETIME}" "${FNH_FULL}")
    local FN_LAST=
    local FN_MASK=
    local FN_FULL=

    case ${PARAM_BAKPOLICY} in
    ${TYPEBAKPOLICY_FULL}) # 全备份
        mr_trace "full backup"
        ;;

    ${TYPEBAKPOLICY_DIFF}) # 差异备份
        mr_trace "diff backup"
        FN_PREFIX=$(file_prefix_backup "${FNH_PREFIX}" "${PARAM_NAME}" "${DATETIME}" "${FNH_DIFF}")
        FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${PARAM_NAME}" "*" "${FNH_FULL}")
        FN_LAST=$(find_file_latest "${PARAM_TYPE}" "${ARG_BMS_BAKDN}" "${FN_MASK}" "" "${DATETIME}")
        mr_trace "prefix=${FN_PREFIX}; mask=${FN_MASK}; find=${FN_LAST}"
        if [ "${FN_LAST}" = "" ]; then
            mr_trace "Error in find the full backup dir for ${FN_PREFIX}"
            return 1
        fi
        ;;

    ${TYPEBAKPOLICY_INCR}) # 增量备份
        mr_trace "incr backup"
        # find the full backup time
        FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${PARAM_NAME}" "*" "${FNH_FULL}")
        FN_FULL=$(find_file_latest "${PARAM_TYPE}" "${ARG_BMS_BAKDN}" "${FN_MASK}" "" "${DATETIME}")
        mr_trace "3 prefix=${FN_PREFIX}; mask=${FN_MASK}; find=${FN_FULL}"
        if [ "${FN_FULL}" = "" ]; then
            mr_trace "Error: not found full backup"
            return -1
        fi
        TM_FULL=$(echo ${FN_FULL} | awk -F_ '{print $3}')

        # check if there exist incr backup
        FN_PREFIX=$(file_prefix_backup "${FNH_PREFIX}" "${PARAM_NAME}" "${DATETIME}" "${FNH_INCR}")
        FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${PARAM_NAME}" "*" "${FNH_INCR}")
        FN_LAST=$(find_file_latest "${PARAM_TYPE}" "${ARG_BMS_BAKDN}" "${FN_MASK}" "" "${DATETIME}")
        mr_trace "1 prefix=${FN_PREFIX}; mask=${FN_MASK}; find=${FN_LAST}"
        if [ ! "${FN_LAST}" = "" ]; then
            # make sure the time is in the first full backup
            TM_TMP=$(echo ${FN_LAST} | awk -F_ '{print $3}')
            if (( $TM_TMP < $TM_FULL )) ; then
                # the incr is not in the last full backup
                FN_LAST=
            fi
        fi
        if [ "${FN_LAST}" = "" ]; then
            # check if there exist diff backup
            FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${PARAM_NAME}" "*" "${FNH_DIFF}")
            FN_LAST=$(find_file_latest "${PARAM_TYPE}" "${ARG_BMS_BAKDN}" "${FN_MASK}" "" "${DATETIME}")
            mr_trace "2 prefix=${FN_PREFIX}; mask=${FN_MASK}; find=${FN_LAST}"
            if [ ! "${FN_LAST}" = "" ]; then
                # make sure the time is in the first full backup
                TM_TMP=$(echo ${FN_LAST} | awk -F_ '{print $3}')
                if (( $TM_TMP < $TM_FULL )) ; then
                    # the diff is not in the last full backup
                    FN_LAST=
                fi
            fi
        fi
        if [ "${FN_LAST}" = "" ]; then
            # fall back to use full backup as previous backup
            FN_LAST="${FN_FULL}"
        fi
        ;;

    *)
        mr_trace "Error in argument backup type"
        return 1
        ;;
    esac

    mr_trace ${PARAM_CALLBACK} "${PARAM_BAKPOLICY}" "${PARAM_CONFIG}" "${FN_PREFIX}" "${FN_LAST}"
    ${PARAM_CALLBACK} "${PARAM_BAKPOLICY}" "${PARAM_CONFIG}" "${ARG_BMS_BAKDN}/${FN_PREFIX}" "${ARG_BMS_DNSAVE}" "${FN_LAST}"
    return 0
}

# 恢复时，使用目录传递文件，调用用户程序处理目录中的文件。
restorecb_files ()
{
    # the policy: full, diff, or incremental
    local PARAM_BAKPOLICY=$1
    shift
    # the config file
    local PARAM_CONFIG=$1
    shift
    # the target dir
    local PARAM_DN_TARGET=$1
    shift
    # the directory save all of changes
    local PARAM_DN_BASE=$1
    shift
    # the incremental backup directory, for diff and incremental
    local PARAM_DN_INCR=$1
    shift
    # the flag if it is not the last one
    local PARAM_FLG_NOTLAST=$1
    shift
    local PARAM_OTHERS=$@

    read_config_file "${PARAM_CONFIG}"

    case ${PARAM_BAKPOLICY} in

    ${TYPEBAKPOLICY_RESTORE}) # 恢复备份最后一步
        mr_trace "restore"
        mv "${PARAM_DN_BASE}" "${PARAM_DN_TARGET}"
        ;;

    ${TYPEBAKPOLICY_FULL}) # 全备份
        mr_trace "process the full dir"
        ;;

    ${TYPEBAKPOLICY_DIFF}) # 差异备份
        mr_trace "process the diff dir"
        mv "${PARAM_DN_INCR}"/* "${PARAM_DN_BASE}"
        ;;

    ${TYPEBAKPOLICY_INCR}) # 增量备份
        mr_trace "process the incr dir"
        mv "${PARAM_DN_INCR}"/* "${PARAM_DN_BASE}"
        ;;

    *)
        mr_trace "Error in argument backup type"
        return 1
        ;;
    esac
    return 0
}

restorecb_mysql ()
{
    # the policy: full, diff, or incremental
    local PARAM_BAKPOLICY=$1
    shift
    # the config file
    local PARAM_CONFIG=$1
    shift
    # the target dir
    local PARAM_DN_TARGET=$1
    shift
    # the directory to be saved
    local PARAM_DN_BASE=$1
    shift
    # the incremental backup directory, for diff and incremental
    local PARAM_DN_INCR=$1
    shift
    # the flag if it is not the last one
    local PARAM_FLG_NOTLAST=$1
    shift
    local PARAM_OTHERS=$@

    read_config_file "${PARAM_CONFIG}"

    local OPTOTHER=
    if [ ! "${DB_CONF}" = "" ]; then
        # --defaults-file has to be the first argument
        OPTOTHER="--defaults-file=${DB_CONF}"
    fi

    case ${PARAM_BAKPOLICY} in

    ${TYPEBAKPOLICY_RESTORE}) # 恢复备份最后一步
        mr_trace "check if exist ${PARAM_DN_BASE}/xtrabackup_logfile.qp"
        if [ -f "${PARAM_DN_BASE}/xtrabackup_logfile.qp" ] ; then
            mr_trace innobackupex --decompress "${PARAM_DN_BASE}"
            innobackupex --decompress "${PARAM_DN_BASE}"
            rm -f "${PARAM_DN_BASE}/xtrabackup_logfile.qp"
        fi
        # restore
        if [ "${DB_LIST}" = "" ]; then
            #   shutdown the whole DB
            which systemctl >/dev/null 2>&1 && systemctl stop mysqld
            which service >/dev/null 2>&1 && service mysql stop
            # move the datadir to a safe place
            local DN_DBBAK="$(echo "${PARAM_DN_TARGET}" | sed -e "s|/$||g")-${DATETIME}"
            mr_trace mv "${PARAM_DN_TARGET}" "${DN_DBBAK}"
            mv "${PARAM_DN_TARGET}" "${DN_DBBAK}"
            mr_trace mkdir -p "${PARAM_DN_TARGET}"
            mkdir -p "${PARAM_DN_TARGET}"

            mr_trace innobackupex ${OPTOTHER} --apply-log "${PARAM_DN_BASE}"
            innobackupex ${OPTOTHER} --apply-log "${PARAM_DN_BASE}"
            mr_trace innobackupex ${OPTOTHER} --copy-back --force-non-empty-directories "${PARAM_DN_BASE}"
            innobackupex ${OPTOTHER} --copy-back --force-non-empty-directories "${PARAM_DN_BASE}"
        else
            mr_trace "recreate mysql datadir"
            #cd /usr; mysql_install_db --user=mysql; cd -
            innobackupex ${OPTOTHER} --apply-log --export "${PARAM_DN_BASE}"
        fi
        chown -R mysql:mysql "${PARAM_DN_TARGET}"
        chmod 700 "${PARAM_DN_TARGET}"
        ;;

    ${TYPEBAKPOLICY_FULL}) # 全备份
        OPTOTHER="${OPTOTHER} --apply-log"
        if [ "${PARAM_FLG_NOTLAST}" = "1" ]; then
            OPTOTHER="${OPTOTHER} --redo-only"
        fi
        mr_trace "check if exist ${PARAM_DN_BASE}/xtrabackup_logfile.qp"
        if [ -f "${PARAM_DN_BASE}/xtrabackup_logfile.qp" ] ; then
            mr_trace innobackupex --decompress "${PARAM_DN_BASE}"
            innobackupex --decompress "${PARAM_DN_BASE}"
            rm -f "${PARAM_DN_BASE}/xtrabackup_logfile.qp"
        fi
        mr_trace innobackupex ${OPTOTHER} ${PARAM_DN_BASE}
        innobackupex ${OPTOTHER} "${PARAM_DN_BASE}"
        ;;

    ${TYPEBAKPOLICY_DIFF}) # 差异备份
        OPTOTHER="${OPTOTHER} --apply-log"
        if [ "${PARAM_FLG_NOTLAST}" = "1" ]; then
            OPTOTHER="${OPTOTHER} --redo-only"
        fi
        ls "${PARAM_DN_BASE}/xtrabackup_logfile"* "${PARAM_DN_INCR}/xtrabackup_logfile"*
        mr_trace "check if exist ${PARAM_DN_BASE}/xtrabackup_logfile.qp"
        if [ -f "${PARAM_DN_BASE}/xtrabackup_logfile.qp" ] ; then
            mr_trace innobackupex --decompress "${PARAM_DN_BASE}"
            innobackupex --decompress "${PARAM_DN_BASE}"
            rm -f "${PARAM_DN_BASE}/xtrabackup_logfile.qp"
        fi
        mr_trace "check if exist ${PARAM_DN_INCR}/xtrabackup_logfile.qp"
        if [ -f "${PARAM_DN_INCR}/xtrabackup_logfile.qp" ] ; then
            mr_trace innobackupex --decompress "${PARAM_DN_INCR}"
            innobackupex --decompress "${PARAM_DN_INCR}"
            rm -f "${PARAM_DN_INCR}/xtrabackup_logfile.qp"
        fi
        mr_trace innobackupex ${OPTOTHER} "${PARAM_DN_BASE}" --incremental-dir="${PARAM_DN_INCR}"
        innobackupex ${OPTOTHER} "${PARAM_DN_BASE}" --incremental-dir="${PARAM_DN_INCR}"
        ;;

    ${TYPEBAKPOLICY_INCR}) # 增量备份
        OPTOTHER="${OPTOTHER} --apply-log"
        if [ "${PARAM_FLG_NOTLAST}" = "1" ]; then
            OPTOTHER="${OPTOTHER} --redo-only"
        fi
        ls "${PARAM_DN_BASE}/xtrabackup_logfile"* "${PARAM_DN_INCR}/xtrabackup_logfile"*
        mr_trace "check if exist ${PARAM_DN_BASE}/xtrabackup_logfile.qp"
        if [ -f "${PARAM_DN_BASE}/xtrabackup_logfile.qp" ] ; then
            mr_trace innobackupex --decompress "${PARAM_DN_BASE}"
            innobackupex --decompress "${PARAM_DN_BASE}"
            rm -f "${PARAM_DN_BASE}/xtrabackup_logfile.qp"
        fi
        mr_trace "check if exist ${PARAM_DN_INCR}/xtrabackup_logfile.qp"
        if [ -f "${PARAM_DN_INCR}/xtrabackup_logfile.qp" ] ; then
            mr_trace innobackupex --decompress "${PARAM_DN_INCR}"
            innobackupex --decompress "${PARAM_DN_INCR}"
            rm -f "${PARAM_DN_INCR}/xtrabackup_logfile.qp"
        fi
        mr_trace innobackupex ${OPTOTHER} "${PARAM_DN_BASE}" --incremental-dir="${PARAM_DN_INCR}"
        innobackupex ${OPTOTHER} "${PARAM_DN_BASE}" --incremental-dir="${PARAM_DN_INCR}"
        ;;

    *)
        mr_trace "Error in argument backup type"
        return 1
        ;;
    esac
    return 0
}

# example: restore_api restorecb_files f "tmp" "backup.conf" "${DATETIME}" "./tmp"
restore_api ()
{
    # the callback function
    local PARAM_CALLBACK=$1
    shift
    # the type of backup file(f)/dir(d)
    local PARAM_TYPE=$1
    shift
    # backup name
    local PARAM_NAME=$1
    shift
    # the config file
    local PARAM_CONFIG=$1
    shift
    # the lastest time to be restored
    local PARAM_DATETIME=$1
    shift
    # the target data dir
    local PARAM_DN_TARGET=$1
    shift

    read_config_file "${PARAM_CONFIG}"

    local TM_START=
    local FNL_LATEST_DIFF=
    local FNL_LATEST_INCR=
    local DN_FULLTMP="/tmp/dnfull-$(uuidgen)"
    local DN_DIFFTMP="/tmp/dndiff-$(uuidgen)"
    local FN_LAST=
    local FN_MASK=
    FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${PARAM_NAME}" "*" "${FNH_FULL}")
    FN_LAST=$(find_file_latest "${PARAM_TYPE}" "${DN_BAK}" "${FN_MASK}" "${TM_START}" "${PARAM_DATETIME}")
    lst_full=($FN_LAST)
    if (( ${#lst_full[*]} > 1 )) ; then
        mr_trace "Error: the # of diff(${lst_full[*]}) should never > 1: $FN_LAST"
        return 1
    fi

    # full
    mr_trace "got full backup: ${FN_LAST} to tmp ${DN_FULLTMP}"
    if [ "d" = "${PARAM_TYPE}" ]; then
        mr_trace cp -r "${FN_LAST}" "${DN_FULLTMP}"
        cp -r "${FN_LAST}" "${DN_FULLTMP}"
    else
        mkdir -p "${DN_FULLTMP}"
        tar -C "${DN_FULLTMP}" -xvf "${FN_LAST}"
    fi
    TM_START=$(echo "${FN_LAST}" | awk -F_ '{print $3}')
    mr_trace "got full backup time: ${TM_START}"

    # find diff backup
    FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${PARAM_NAME}" "*" "${FNH_DIFF}")
    FNL_LATEST_DIFF=$(find_file_latest "${PARAM_TYPE}" "${DN_BAK}" "${FN_MASK}" "" "${PARAM_DATETIME}")
    lst_diff=(${FNL_LATEST_DIFF})
    if (( ${#lst_diff[*]} > 1 )) ; then
        mr_trace "Error: the # of diff(${lst_diff[*]}) should never > 1: $FNL_LATEST_DIFF"
        return 1
    elif (( ${#lst_diff[*]} > 0 )) ; then
        # make sure the time is in the first full backup
        TM_TMP=$(echo ${FNL_LATEST_DIFF} | awk -F_ '{print $3}')
        if (( $TM_TMP < $TM_START )) ; then
            # the diff is not in the last full backup
            FNL_LATEST_DIFF=
            lst_diff=($FNL_LATEST_DIFF)
        fi
    fi
    mr_trace "got diff backup for time(0,${PARAM_DATETIME}): ${FNL_LATEST_DIFF}"

    # find incr backup
    FN_MASK=$(file_prefix_backup "${FNH_PREFIX}" "${PARAM_NAME}" "*" "${FNH_INCR}")
    FNL_LATEST_INCR=$(find_file_latest "${PARAM_TYPE}" "${DN_BAK}" "${FN_MASK}" "${TM_START}" "${PARAM_DATETIME}")
    lst_incr=($FNL_LATEST_INCR)
    mr_trace "got incr backups for time (${TM_START}, ${PARAM_DATETIME}): $FNL_LATEST_INCR"

    FLG_REDO=0
    if (( ${#lst_diff[*]} + ${#lst_incr[*]} > 0 )) ; then
        FLG_REDO=1
    fi

    # prepare full
    ${PARAM_CALLBACK} ${TYPEBAKPOLICY_FULL} "${PARAM_CONFIG}" "${PARAM_DN_TARGET}" "${DN_FULLTMP}" "" "1"
    mr_trace "${PARAM_CALLBACK} return ? $?"

    # diff
    if [ ! "$FNL_LATEST_DIFF" = "" ] ; then
        if [ "d" = "${PARAM_TYPE}" ]; then
            mr_trace cp -r "${FNL_LATEST_DIFF}" "${DN_DIFFTMP}"
            cp -r "${FNL_LATEST_DIFF}" "${DN_DIFFTMP}"
        else
            mkdir -p "${DN_DIFFTMP}"
            tar -C "${DN_DIFFTMP}" -xvf "${FNL_LATEST_DIFF}"
        fi
    fi

    FLG_REDO=0
    if (( ${#lst_incr[*]} > 0 )) ; then
        FLG_REDO=1
    fi

    ${PARAM_CALLBACK} ${TYPEBAKPOLICY_DIFF} "${PARAM_CONFIG}" "${PARAM_DN_TARGET}" "${DN_FULLTMP}" "${DN_DIFFTMP}" "${FLG_REDO}"
    mr_trace "${PARAM_CALLBACK} 2 return ? $?"
    #rm -rf "${DN_DIFFTMP}"

    CNT=${#lst_incr[*]}
    for FN_TMP_INCR in ${FNL_LATEST_INCR}; do
        CNT=$(( $CNT - 1))
        FLG_REDO=0
        if (( $CNT > 0 )) ; then
            FLG_REDO=1
        fi
        DN_DIFFTMP="/tmp/dnincr-$(uuidgen)"
        if [ "d" = "${PARAM_TYPE}" ]; then
            mr_trace cp -r "${FN_TMP_INCR}" "${DN_DIFFTMP}"
            cp -r "${FN_TMP_INCR}" "${DN_DIFFTMP}"
        else
            mkdir -p "${DN_DIFFTMP}"
            tar -C "${DN_DIFFTMP}" -xvf "${FN_TMP_INCR}"
        fi
        ${PARAM_CALLBACK} ${TYPEBAKPOLICY_DIFF} "${PARAM_CONFIG}" "${PARAM_DN_TARGET}" "${DN_FULLTMP}" "${DN_DIFFTMP}" "${FLG_REDO}"
        mr_trace "${PARAM_CALLBACK} 3 return ? $?"
        #rm -rf "${DN_DIFFTMP}"
    done
    ${PARAM_CALLBACK} ${TYPEBAKPOLICY_RESTORE} "${PARAM_CONFIG}" "${PARAM_DN_TARGET}" "${DN_FULLTMP}" "" "0"
    mr_trace "${PARAM_CALLBACK} 4 return ? $?"

    #rm -rf "${DN_FULLTMP}"
}

# echo 'SHOW VARIABLES WHERE Variable_Name LIKE "%innodb_log_files_in_group"' | mysql -u ${DB_USER} -p${DB_PW}

test_backup_and_restore_mysql ()
{
    CUR=0
    DB_CONF="/etc/mysql/my.cnf"

    NAME="mysqltest"
    DB_NAME_TMP="testdb"
    DB_PW_TMP="testdb"
    DB_TABLE_TMP="testtab"

    #FN_CONF_TMP="/tmp/conf-$(uuidgen)"
    FN_CONF_TMP="test.conf"
    cp "${FN_CONF}" "${FN_CONF_TMP}"
    sed -i \
        -e 's|^FNH_PREFIXX=.*$|FNH_PREFIX=test|' \
        -e "s|^DB_USER=.*$|DB_USER=${DB_NAME_TMP}|" \
        -e "s|^DB_PW=.*$|DB_PW=${DB_PW_TMP}|" \
        -e "s|^DB_LIST=.*$|DB_LIST=|" \
        "${FN_CONF_TMP}"

    read_config_file "${FN_CONF_TMP}"
    EXEC_DUMPDB="mysqldump --flush-logs -u ${DB_USER} -p${DB_PW} --skip-lock-tables --quick"
    mkdir -p "${DN_BAK}"

if [ 1 = 1 ]; then # disable create test data
    # 1 create a temp database
    mr_trace "This test will create a test user $DB_NAME_TMP ..."
    # add test DB user
    cat << EOF > /tmp/db-testusr.sql
DROP DATABASE IF EXISTS ${DB_NAME_TMP};
GRANT USAGE ON *.* TO '${DB_NAME_TMP}'@'localhost';
DROP USER '${DB_NAME_TMP}'@'localhost';

CREATE USER '${DB_NAME_TMP}'@'localhost' IDENTIFIED BY '${DB_PW_TMP}';
GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${DB_NAME_TMP}'@'localhost';

CREATE DATABASE IF NOT EXISTS ${DB_NAME_TMP};
GRANT ALL PRIVILEGES ON ${DB_NAME_TMP}.* TO '${DB_NAME_TMP}'@'localhost';

FLUSH PRIVILEGES;
EOF
    mysql -u root -p < /tmp/db-testusr.sql

    echo "SHOW DATABASES;" | mysql -u ${DB_USER} -p${DB_PW}
    if [ ! "$?" = "0" ] ; then
        mr_trace "Please make sure the mysql is running!"
        exit 1
    fi

    mr_trace "Make sure you have datadir set in your my.cnf ..."
    MYDATADIR=$(echo 'SHOW VARIABLES WHERE Variable_Name LIKE "%dir"' | mysql -u ${DB_USER} -p${DB_PW} | grep datadir | awk '{print $2}')
    if [ "${MYDATADIR}" = "" ]; then
        mr_trace "Error: not found datadir: ${MYDATADIR}"
        exit 1
    fi
    grep "datadir=${MYDATADIR}" "${DB_CONF}"
    if [ ! "$?" = "0" ]; then
        mr_trace "Please add followning in your my.cnf:"
        mr_trace "[mysqld]"
        mr_trace "datadir=${MYDATADIR}"
    fi
    mr_trace "Make sure you can access the directory ${MYDATADIR} .."
    ls "${MYDATADIR}"
    if [ ! "$?" = "0" ]; then
        mr_trace "Please make sure you can access ${MYDATADIR}"
        exit 1
    fi

    mr_trace "Creating test database: $DB_NAME_TMP ..."
    cat << EOF > /tmp/db-test.sql
CREATE DATABASE IF NOT EXISTS ${DB_NAME_TMP};
USE ${DB_NAME_TMP};
SHOW TABLES;
CREATE TABLE IF NOT EXISTS ${DB_TABLE_TMP} (name VARCHAR(20), owner VARCHAR(20), species VARCHAR(20), sex CHAR(1), birth DATE, death DATE);
TRUNCATE ${DB_TABLE_TMP};
EOF
    mysql -u ${DB_USER} -p${DB_PW} < /tmp/db-test.sql
    if [ ! "$?" = "0" ]; then
        mr_trace "Error in create DB, please make sure there exist user ${DB_USER} in DB!"
        exit 1
    fi
    mr_trace "Full dump the original blank database $DB_NAME_TMP ..."
    ${EXEC_DUMPDB} ${DB_NAME_TMP} > ${DB_NAME_TMP}-${CUR}-full.sql
    mr_trace "Full backup the original blank database $DB_NAME_TMP ..."
    backup_api backupcb_mysql "d" "${TYPEBAKPOLICY_FULL}" "${NAME}" "${FN_CONF_TMP}" "${MYDATADIR}" "${DN_BAK}"

    mr_trace "wait 2 seconds ..."; sleep 2

    DATETIME=`date +%Y%m%d%H%M%S`
    mr_trace "update the datetime to ${DATETIME}"

    LST_TEST_DATA=(
        "sweetheart Wartian dog F 2010-11-3 2015-11-11"
        "babe John dog F 2009-5-17 2015-11-11"
        "boyfriend Wellington dog M 2009-6-9 2015-11-11"
        "honey White dog M 2008-3-15 2015-11-11"
        "muffin Wilman dog M 2009-2-6 2015-11-11"
        "cute Wolski dog M 2008-11-8 2015-11-11"
        "cute Pirkko dog M 2008-11-8 2015-11-11"
        "cute Paula dog M 2008-11-8 2015-11-11"
        "cute Karl dog M 2008-11-8 2015-11-11"
        "cute Matti dog M 2008-11-8 2015-11-11"
        "cute Zbyszek dog M 2008-11-8 2015-11-11"
        )
    # 2 insert some records and save it as both sql file and backup
    lst=(${LST_TEST_DATA[$CUR]})
    CUR=$(( $CUR + 1 ))
    mr_trace "# of test records=${#LST_TEST_DATA[*]}"
    mr_trace "current records[$CUR]=${lst}"
    mr_trace "USE ${DB_NAME_TMP}; INSERT INTO ${DB_TABLE_TMP} (name,owner,species,sex,birth,death) VALUES ('${lst[0]}','${lst[1]}','${lst[2]}','${lst[3]}','${lst[4]}','${lst[5]}');"
    echo "USE ${DB_NAME_TMP}; INSERT INTO ${DB_TABLE_TMP} (name,owner,species,sex,birth,death) VALUES ('${lst[0]}','${lst[1]}','${lst[2]}','${lst[3]}','${lst[4]}','${lst[5]}');" | mysql -u ${DB_USER} -p${DB_PW}
    ${EXEC_DUMPDB} ${DB_NAME_TMP} > ${DB_NAME_TMP}-${CUR}-diff.sql
    backup_api backupcb_mysql "d" "${TYPEBAKPOLICY_DIFF}" "${NAME}" "${FN_CONF_TMP}" "${MYDATADIR}" "${DN_BAK}"

    # 3 redo 2 until 10 times
    while (( $CUR < ${#LST_TEST_DATA[*]} )) ; do
        mr_trace "wait 2 seconds ..."; sleep 2
        DATETIME=`date +%Y%m%d%H%M%S`
        mr_trace "update the datetime to ${DATETIME}"

        lst=(${LST_TEST_DATA[$CUR]})
        CUR=$(( $CUR + 1 ))
        mr_trace "USE ${DB_NAME_TMP}; INSERT INTO ${DB_TABLE_TMP} (name,owner,species,sex,birth,death) VALUES ('${lst[0]}','${lst[1]}','${lst[2]}','${lst[3]}','${lst[4]}','${lst[5]}');"
        echo "USE ${DB_NAME_TMP}; INSERT INTO ${DB_TABLE_TMP} (name,owner,species,sex,birth,death) VALUES ('${lst[0]}','${lst[1]}','${lst[2]}','${lst[3]}','${lst[4]}','${lst[5]}');" | mysql -u ${DB_USER} -p${DB_PW}
        ${EXEC_DUMPDB} ${DB_NAME_TMP} > ${DB_NAME_TMP}-${CUR}-incr.sql
        backup_api backupcb_mysql "d" "${TYPEBAKPOLICY_INCR}" "${NAME}" "${FN_CONF_TMP}" "${MYDATADIR}" "${DN_BAK}"
    done

fi # disable create test data

    mr_trace "datadir 1000=${MYDATADIR}"
    if [ "${MYDATADIR}" = "" ]; then
        mr_trace "Error: not found datadir: ${MYDATADIR}"
        exit 1
    fi
    # 4 restore the database and compare the corespond sql file for each backup file
    #   drop the database first
    echo "DROP DATABASE IF EXISTS ${DB_NAME_TMP};" | mysql -u ${DB_USER} -p${DB_PW}

    #   restore
    #debug
    #DATETIME=20151112211928
    restore_api restorecb_mysql "d" "${NAME}" "${FN_CONF_TMP}" "${DATETIME}" "${MYDATADIR}"
if [ 0 = 1 ]; then
    ls -l --time-style=+%S "${MYDATADIR}" | grep ^d | awk '{print $7}' | while read a; do mr_trace "process db dir $a ..."; rm -rf "${DN_DBBAK}/$a"; mv "${MYDATADIR}/$a" "${DN_DBBAK}"; done
    mr_trace rm -rf "${MYDATADIR}"
    rm -rf "${MYDATADIR}"
    mr_trace mv "${DN_DBBAK}" "${MYDATADIR}"
    mv "${DN_DBBAK}" "${MYDATADIR}"
fi
    # in file DB_CONF=/etc/mysql/my.cnf
    # port = 3306
    # innodb_data_home_dir = /var/lib/mysql
    # for mysql: mysql -uUSER -p -e 'SHOW VARIABLES WHERE Variable_Name LIKE "%dir"'
    #chown -R mysql:mysql /var/lib/mysql
    # SELECT Variable_Value FROM GLOBAL_VARIABLES WHERE Variable_Name = "datadir"
    #local DATADIR=$(echo 'SHOW VARIABLES WHERE Variable_Name LIKE "%dir"' | mysql -u ${DB_USER} -p${DB_PW} | grep datadir | awk '{print $2}')
    chown -R mysql:mysql "${MYDATADIR}"

    mr_trace systemctl restart mysqld
    which systemctl >/dev/null 2>&1 && systemctl restart mysqld
    which service >/dev/null 2>&1 && service mysql restart
    # check the results
    ${EXEC_DUMPDB} ${DB_NAME_TMP} > ${DB_NAME_TMP}-backupped.sql
    FN_LAST=$(find . -maxdepth 1 -type f -name "${DB_NAME_TMP}-*-incr.sql" | awk -F- 'BEGIN{c=-1;ret="";}{val=$2; if (c < val) {ret=$0; c=val;} }END{print ret;}')
    mr_trace diff -Nu ${DB_NAME_TMP}-backupped.sql ${FN_LAST}
    diff -Nu ${DB_NAME_TMP}-backupped.sql ${FN_LAST}

    #echo "DROP DATABASE IF EXISTS ${DB_NAME_TMP};" | mysql -u ${DB_USER} -p${DB_PW}
    #which systemctl >/dev/null 2>&1 && systemctl stop mysqld
    #which service >/dev/null 2>&1 && service mysql stop
}

test_backup_and_restore_files ()
{
    # install bindfs
    # yaourt bindfs
    # and bind with --ctime-from-mtime, so we can change the ctime of a file

    CUR=0
    NAME=test

    read_config_file "${FN_CONF}"

if [ 1 = 1 ]; then
    rm -rf ../test/*
    rm -rf tmp
    mkdir -p tmp
    bindfs --ctime-from-mtime tmp tmp

    LST_TEST_DATA=(
        20140211
        20140630
        20150106
        20150916
        )

    DATETIME="${LST_TEST_DATA[$CUR]}000000"
    CUR=$(( $CUR + 1 ))
    touch -a -m -d ${DATETIME:0:8} tmp/a tmp/b
    backup_api backupcb_files "f" "${TYPEBAKPOLICY_FULL}" "${NAME}" "${FN_CONF}" "tmp" "${DN_BAK}"

    DATETIME="${LST_TEST_DATA[$CUR]}000000"
    CUR=$(( $CUR + 1 ))
    touch -a -m -d ${DATETIME:0:8} tmp/c tmp/d
    backup_api backupcb_files "f" "${TYPEBAKPOLICY_DIFF}" "${NAME}" "${FN_CONF}" "tmp" "${DN_BAK}"

    while (( $CUR < ${#LST_TEST_DATA[*]} )) ; do
        DATETIME="${LST_TEST_DATA[$CUR]}000000"
        CUR=$(( $CUR + 1 ))
        touch -a -m -d ${DATETIME:0:8} tmp/e-$CUR tmp/f-$CUR
        backup_api backupcb_files "f" "${TYPEBAKPOLICY_INCR}" "${NAME}" "${FN_CONF}" "tmp" "${DN_BAK}"
    done

    sudo umount tmp
fi

    # restore
    restore_api restorecb_files "f" "${NAME}" "${FN_CONF}" "${DATETIME}" "./tmp3"
}

#test_backup_and_restore_files
#test_backup_and_restore_mysql

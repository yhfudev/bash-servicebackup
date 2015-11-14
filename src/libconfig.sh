#!/bin/bash
#####################################################################
# bash library
# config file reader for bash scripts:
#   read_config_file
#
# Copyright 2014 Yunhui Fu
# License: GPL v3.0 or later
#####################################################################

# read config file from pipe
read_config_file () {
    ### Read in some system-wide configurations (if applicable) but do not override
    ### the user's environment
    PARAM_FN_CONF="$1"
    mr_trace "parse config file $1"
    if [ -e "$PARAM_FN_CONF" ]; then
        while read LINE; do
            REX='^[^# ]*='
            if [[ ${LINE} =~ ${REX} ]]; then
                VARIABLE=$(echo "${LINE}" | awk -F= '{print $1}' )
                VALUE0=$(echo "${LINE}" | awk -F= '{print $2}' )
                VALUE=$( unquote_filename "${VALUE0}" )
                V0="RCFLAST_VAR_${VARIABLE}"
                if [ "z${!V0}" == "z" ]; then
                    if [ "z${!VARIABLE}" == "z" ]; then
                        eval "${V0}=\"${VALUE}\""
                        eval "${VARIABLE}=\"${VALUE}\""
                        #mr_trace "Setting ${VARIABLE}=${VALUE} from $PARAM_FN_CONF"
                    #else mr_trace "Keeping $VARIABLE=${!VARIABLE} from user environment"
                    fi
                else
                    eval "${V0}=\"${VALUE}\""
                    eval "${VARIABLE}=\"${VALUE}\""
                    #mr_trace "Setting ${VARIABLE}=${VALUE} from $PARAM_FN_CONF"
                fi
                #mr_trace "VARIABLE=${VARIABLE}; VALUE=${VALUE}"
            fi
        done < "$PARAM_FN_CONF"
    fi
}

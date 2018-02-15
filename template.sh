#!/bin/bash

set -euo pipefail

########################################################
#
# Template 
#
########################################################

#********************************************************
#
# Starfish Storage Corporation ("COMPANY") CONFIDENTIAL
# Unpublished Copyright (c) 2011-2018 Starfish Storage Corporation, All Rights Reserved.
#
# NOTICE:  All information contained herein is, and remains the property of COMPANY. The intellectual and
# technical concepts contained herein are proprietary to COMPANY and may be covered by U.S. and Foreign
# Patents, patents in process, and are protected by trade secret or copyright law. Dissemination of this
# information or reproduction of this material is strictly forbidden unless prior written permission is
# obtained from COMPANY.  Access to the source code contained herein is hereby forbidden to anyone except
# current COMPANY employees, managers or contractors who have executed Confidentiality and Non-disclosure
# agreements explicitly covering such access.
#
# ANY REPRODUCTION, COPYING, MODIFICATION, DISTRIBUTION, PUBLIC  PERFORMANCE, OR PUBLIC DISPLAY OF OR
# THROUGH USE  OF THIS  SOURCE CODE  WITHOUT  THE EXPRESS WRITTEN CONSENT OF COMPANY IS STRICTLY PROHIBITED,
# AND IN VIOLATION OF APPLICABLE LAWS AND INTERNATIONAL TREATIES.  THE RECEIPT OR POSSESSION OF  THIS SOURCE
# CODE AND/OR RELATED INFORMATION DOES NOT CONVEY OR IMPLY ANY RIGHTS TO REPRODUCE, DISCLOSE OR DISTRIBUTE
# ITS CONTENTS, OR TO MANUFACTURE, USE, OR SELL ANYTHING THAT IT  MAY DESCRIBE, IN WHOLE OR IN PART.  
#
# FOR U.S. GOVERNMENT CUSTOMERS REGARDING THIS DOCUMENTATION/SOFTWARE
#   These notices shall be marked on any reproduction of this data, in whole or in part.
#   NOTICE: Notwithstanding any other lease or license that may pertain to, or accompany the delivery of,
#   this computer software, the rights of the Government regarding its use, reproduction and disclosure are
#   as set forth in Section 52.227-19 of the FARS Computer Software-Restricted Rights clause.
#   RESTRICTED RIGHTS NOTICE: Use, duplication, or disclosure by the Government is subject to the
#   restrictions as set forth in subparagraph (c)(1)(ii) of the Rights in Technical Data and Computer
#   Software clause at DFARS 52.227-7013.
#
#********************************************************

# Set variables
readonly VERSION="1.X February 1, 2018"
PROG="${0##*/}"
readonly NOW=$(date +"%Y%m%d-%H%M%S")
readonly SFHOME="${SFHOME:-/opt/starfish}"
readonly LOGDIR="$SFHOME/log/${PROG%.*}"
readonly LOGFILE="${LOGDIR}/$(basename ${BASH_SOURCE[0]} '.sh')-$NOW.log"

# Only necessary for report scripts
readonly REPORTSDIR="reports"
readonly REPORTFILE="${REPORTSDIR}/$(basename ${BASH_SOURCE[0]} '.sh')-$NOW.html"

# Global variables
SFVOLUMES=()
EMAIL=""
EMAILFROM=root

# Variables for SQL query scripts
QUERY=""
SQLURI=""
SQLOUTPUT=""

logprint() {
  echo "$(date +%D-%T): $*" >> $LOGFILE
}

email_alert() {
  (echo -e "$1") | mailx -s "$PROG Failed!" -a $LOGFILE -r $EMAILFROM $EMAIL
}

email_notify() {
  (echo -e "$1") | mailx -s "$PROG Completed Successfully" -r $EMAILFROM $EMAIL
}

fatal() {
  local msg="$1"
  echo "${msg}" >&2
  exit 1
}

check_parameters_value() {
  local param="$1"
  [ $# -gt 1 ] || fatal "Missing value for parameter ${param}"
}

usage () {
  local msg="${1:-""}"
  if [ ! -z "${msg}" ]; then
    echo "${msg}" >&2
  fi
  cat <<EOF

Starfish Report
$VERSION

$PROG [options] 

   -h, --help              - print this help and exit

Required:
   --email <recipients>		 - Email reports to <recipients> (comma separated)

Optional:
   --volume <SF volume name>  - Starfish volume name (if not specified, all volumes are included)
   --from <sender>	      - Email sender (default: root)

Examples:
$PROG --volume nfs1: --from sysadmin@company.com  --email a@company.com,b@company.com
Run $PROG for all SF volume nfs1:.  Email results to users a@company.com and b@company.com, coming from sysadmin@company.com

EOF
exit 1
}

parse_input_parameters() {
  local errorcode
  local volume
  logprint "Parsing input parameters"
  while [[ $# -gt 0 ]]; do
    case $1 in
    "--volume")
      check_parameters_value "$@"
      shift
      volume=$1
      [[ $volume == *: ]] && volume=${volume::-1}
      SFVOLUMES+=("$volume")
      ;;
    "--email")
      check_parameters_value "$@"
      shift
      EMAIL=$1
      ;;
    "--from")
      check_parameters_value "$@"
      shift
      EMAILFROM=$1
      ;;
    *)
      logprint "input parameter: $1 unknown. Exiting.."
      fatal "input parameter: $1 unknown. Exiting.."
      ;;
    esac
    shift
  done

# Check for required parameters
  if [[ $EMAIL == "" ]]; then
    echo "Required parameter missing. Exiting.."
    logprint "Required parameter missing. Exiting.."
    exit 1
  fi
  if [[ ${#SFVOLUMES[@]} -eq 0 ]]; then
    logprint " SF volumes: [All]" 
  else
    logprint " SF volume: ${SFVOLUMES[@]}"
  fi
  logprint " email from: $EMAILFROM"
  logprint " email recipients: $EMAIL"
}

verify_sf_volume() {
  local sf_vol_list_output
  local errorcode
  logprint "Checking if $1 exists in Starfish"
  set +e
  sf_vol_list_output=$(sf volume list | grep $1)
  set -e
  if [[ -z "$sf_vol_list_output" ]]; then
    errorcode="Starfish volume $1 is not a Starfish configured volume. The following process can be followed to create a new Starfish volume for use with this script, if necessary:
1) mkdir /mnt/sf/$1
2) run 'mount -o noatime,vers=3 {isilon_host:/path_to_snapshot_data} /mnt/sf/$1'
3) sf volume add $1 /mnt/sf/$1
4) sf volume list (to verify volume added)
5) sf scan list (to verify SF can access and scan the volume)
6) sf scan pending (to verify the volume does not have a currently running scan)
7) umount /mnt/sf/$1 (unmount volume in preparation for running this script)"
    logprint "$errorcode"
    echo -e "$errorcode"
    email_alert "$errorcode"
    exit 1
  fi
  logprint "$1 found in Starfish"
}

check_mailx_exists() {
  logprint "Checking for mailx"
  if [[ $(type -P mailx) == "" ]]; then
    logprint "Mailx not found, exiting.."
    echo "mailx is required for this script. Please install mailx with yum or apt-get and re-run" 2>&1
   exit 1
  else
    logprint "Mailx found"
  fi
}

check_postgres_login() {
  local urifound
  urifound="false"
  while read LINE; do
    if [[ ${LINE:0:6} = "pg_uri" ]]; then
      set +e
      SQLURI=`echo $LINE | cut -c 8-`
      set -e
      logprint "pg_uri found"    
      urifound="true"
    fi
  done < $SFHOME/etc/99-local.ini
  if [[ "$urifound" == "false" ]]; then
    fatal "pg_uri not found in $SFHOME/etc/99-local.ini! Script exiting.."
  fi
}

# Used for query scripts
build_sql_query() {
  logprint "Building SQL query"
  local volumes_query=""
  if [[ ${#SFVOLUMES[@]} > 0 ]]; then
    volumes_query="WHERE (volume_name = '${SFVOLUMES[0]}')"
    for volume in "${SFVOLUMES[@]:1}"
      do
        volumes_query="$volumes_query OR (volume_name = '$volume')"
      done
  fi
  QUERY="SELECT
      volume_name as \"Volume\",
      user_name as \"User Name\",
      group_name as \"Group Name\",
      SUM(ROUND((size)::DECIMAL/(1024*1024*1024), 2)) AS \"size (GB)\",
      SUM(count)::BIGINT AS \"Number of Files\",
      SUM(ROUND((cost)::DECIMAL,2)) AS \"Cost($)\"
    FROM sf_reports.last_time_generic_current $volumes_query
    GROUP BY user_name,volume_name,size,group_name
    ORDER BY size DESC
    LIMIT 20"
  logprint "SQL query set"
  logprint $QUERY
}

execute_sql_query() {
  local errorcode
  logprint "executing SQL query"
  set +e
# run psql. -F specifies delimiter, -A unaligned output, -H is HTML output
  SQL_OUTPUT=`psql $SQLURI -F, -A -H -c "$QUERY" > $REPORTFILE 2>&1
  errorcode=$?
  set -e
  if [[ $errorcode -eq 0 ]]; then
    logprint "SQL query executed successfully"
  else
    logprint "SQL query failed with errorcode: $errorcode. Exiting.."
    echo -e "SQL query failed with errorcode: $errorcode. Exiting.."
    email_alert "SQL query failed with errorcode: $errorcode"
    exit 1
  fi
}

format_results() {
  logprint "Formatting results"
echo -e $SQL_OUTPUT > $REPORTFILE
  
#  DAY=`date '+%Y%m%d'`
#  `echo "$SQL_OUTPUT" | awk -v emfrom="$EMAILFROM" -v emto="$EMAIL" -F',' 'BEGIN \
#    {
#      print "From: " emfrom "\n<br>"
#      print "To: " emto "\n<br>"
#      printf ("%s\n<br>", "Subject: Starfish report")
#      print "<html><body><table border=1 cellspace=0 cellpadding=3>"
#      print "<td>Username</td><td>Volume</td><td>Start Date</td><td>End Date</td><td>Percent Delta</td><td>Previous Size GB</td><td>Current Size GB</td><td>Delta Size GB</td>"
#    } 
#    {
#      print "<tr>"
#      print "<td>"$1"</td>";
#      print "<td>"$2"</td>";
#      print "<td>"$3"</td>";
#      print "<td>"$4"</td>";
#      print "<td>"$5"</td>";
#      print "<td>"$6"</td>";
#      print "<td>"$7"</td>";
#      print "<td>"$8"</td>";
#      print "</tr>"
#    } 
#    END \
#    {
#      print "</table></body></html>"
#      print "<br />"
#      print "<br />"
#    }' > $REPORTFILE` 
#  logprint "Results formatted"
}

email_report() {
  if [[ ${#SFVOLUMES[@]} -eq 0 ]]; then
    SFVOLUMES+="[All]"
  fi
  local subject="Report: Starfish Report"
  logprint "Emailing results to $EMAIL"
  (echo -e "
From: $EMAILFROM
To: $EMAIL
Subject: $subject")| mailx -s "$subject" -a $REPORTFILE -r $EMAILFROM $EMAIL
}

# if first parameter is -h or --help, call usage routine
if [ $# -gt 0 ]; then
  [[ "$1" == "-h" || "$1" == "--help" ]] && usage
fi

# Check if logdir and logfile exists, and create if it doesnt
[[ ! -e $LOGDIR ]] && mkdir $LOGDIR
[[ ! -e $LOGFILE ]] && touch $LOGFILE
logprint "---------------------------------------------------------------"
logprint "Script executing"
logprint "$VERSION"
echo "Script starting, in process"

# Check for reports directory, and create if it doesn't exist
[[ ! -e $REPORTSDIR ]] && mkdir $REPORTSDIR

# start script
echo "Step 1: Parse input parameters"
parse_input_parameters $@
echo "Step 1 Complete"
  if [[ ${#SFVOLUMES[@]} > 0 ]]; then
    echo "Step 1b: Verify volumes exist in SF"
    for volume in "${SFVOLUMES[@]}"
      do
        verify_sf_volume $volume
      done
    echo "Step 1b Complete"
  fi
echo "Step 2 Complete"
echo "Step 3: Verify prereq's (postgres login and mailx)"
check_postgres_login
echo "Step 3 - postgres login verified"
check_mailx_exists
echo "Step 3 - mailx verified"
echo "Step 3 Complete"
echo "Step 4: Build SQL query"
build_sql_query
echo "Step 4 Complete"
echo "Step 5: Execute SQL query"
execute_sql_query
echo "Step 5 Complete"
echo "Step 6: Format results into HTML"
#exit 1
format_results
echo "Step 6 Complete"
echo "Step 7: Email results"
email_report
echo "Step 7 Complete"
echo "Script complete"



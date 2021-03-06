#!/bin/bash

# This script:
# -> Applies DDL and DML migrations including resolving tokens in .dml.sql files using their adjacent .json token file

fn_exit_on_error ()
{
  # Exit script if you try to use an uninitialized variable.
  set -o nounset

  # Exit script if a statement returns a non-true return value.
  set -o errexit

  # Use the error status of the first failure, rather than that of the last item in a pipeline.
  set -o pipefail
}

fn_exit_on_error_off ()
{
  set +o nounset
  set +o errexit
  set +o pipefail
}

log ()
{
  fn_exit_on_error_off
  if [ "${TEST_MODE}" == true ]; then
    echo "${SCRIPT_NAME} -> TEST MODE -> ${1}"
  else
    echo "${SCRIPT_NAME} -> ${1}"
  fi
  fn_exit_on_error
}

on_exit ()
{
  echo
  log "Cleaning up..."
  find . -name "*.tmp.*" | xargs rm -f
  find . -name "*.tmp" | xargs rm -f
}
trap on_exit EXIT INT TERM

exit_with_code ()
{
  on_exit

  echo
  log "END `date '+%Y-%m-%d %H:%M:%S'`"
  exit ${1}
}

fn_exit_on_error

SCRIPT_DIR="$( cd "$(dirname "${0}")" ; pwd -P )"
SCRIPT_DIR_NAME=${SCRIPT_DIR##*/}
SCRIPT_NAME=`basename ${0}`
SCRIPT_NAME_NO_SUFFIX=${SCRIPT_NAME%.*}

WHOAMI=`whoami`
log "START `date '+%Y-%m-%d %H:%M:%S'`"
log "ENTER as user ${WHOAMI}..."
echo

if [ $# -lt 4 ]; then
  log "Usage: migratex.sh ENV_ID GCP_PROJECT_ID SPANNER_INSTANCE_ID SPANNER_DATABASE_ID"
  exit_with_code 2

  else
    export ENV_ID=${1}
    export GCP_PROJECT_ID=${2}
    export SPANNER_INSTANCE_ID=${3}
    export SPANNER_DATABASE_ID=${4}
fi

TEST_MODE=false
TEST_MIGRATIONS="./008_bar_create_indexes.ddl.up.sql
./001_foo_create.ddl.up.sql
./007_foo_bar_load.dml.sql
./002_bar_create.ddl.up.sql
./006_foo_create_indexes.ddl.up.sql
./003_foo_load.all.dml.sql
./004_foo_load.dev.dml.sql
./005_bar_load.dev.dml.sql
./004_foo_load.uat.dml.sql"
TEST_LAST_MIGRATION_DDL="Version
2"
TEST_LAST_MIGRATION_DML="Version
1"
TEST_DML="SELECT * from
SchemaMigrations;

SELECT Version from SchemaMigrations;
"

echo
log "TEST_MODE=${TEST_MODE}"
log "ENV_ID=${ENV_ID}"
log "GCP_PROJECT_ID=${GCP_PROJECT_ID}"
log "SPANNER_INSTANCE_ID=${SPANNER_INSTANCE_ID}"
log "SPANNER_DATABASE_ID=${SPANNER_DATABASE_ID}"
echo

# -> FUNCTIONS ----------------------------------------
fn_create_dml_table_if_necessary ()
{
  echo
  log "ENTER fn_create_dml_table_if_necessary..."

  if [ "${TEST_MODE}" == true ]; then
    log "Skipping"

  else
    fn_exit_on_error_off
    gcloud spanner databases ddl update ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --ddl="CREATE TABLE DataMigrations (Version INT64 NOT NULL, Dirty BOOL NOT NULL) PRIMARY KEY (Version)" --format=json
    result_code=$?
    if [ "${result_code}" -ne 0 ]; then
      log "PLEASE IGNORE ERROR: DML table already exists, no action required "

    else
      log "Created DML table"
    fi
    fn_exit_on_error
  fi

  log "LEAVE fn_create_dml_table_if_necessary..."
  echo
}

fn_replace_tokens ()
{
  echo
  log "ENTER fn_replace_tokens..."

  TOKEN_FILE=$(basename ${1} .tmp.dml.sql).json

  if [ -f ${TOKEN_FILE} ]; then
    log "Replacing tokens using token file ${TOKEN_FILE}"

    KEYS=()
    while IFS='' read -r line; do
      KEYS+=("$line")
    done < <(jq -r 'keys[]' ${TOKEN_FILE})

    for KEY in ${KEYS[@]}; do
      VALUE=$(jq -r --arg key "${KEY}" '.[$key]' ${TOKEN_FILE})
      log "Replacing '${KEY}' with '${VALUE}'"
      TMP_FILE=${1}.tmp
      sed "s/@${KEY}@/${VALUE}/g" "${1}" > "${TMP_FILE}" && mv ${TMP_FILE} ${1}
    done
  else
    log "Skipping replacing tokens, no token file ${TOKEN_FILE}"
  fi

  log "LEAVE fn_replace_tokens..."
  echo
}

fn_process_tmpl ()
{
  echo
  log "ENTER fn_process_tmpl..."

  DML_FILE=$(basename ${1} .dml.sql).tmp.dml.sql

  log "Will stage DML ${1} to ${DML_FILE} prior to replacing any tokens"

  if [ "${TEST_MODE}" == true ]; then
    log "Skipping"
  else
    cp -f ${1} ${DML_FILE}
    fn_replace_tokens ${DML_FILE}
  fi

  log "LEAVE fn_process_tmpl..."
  echo
}

fn_count_migrations ()
{
  echo
  log "ENTER fn_count_migrations..."

  if [ "${TEST_MODE}" == true ]; then
    MIGRATIONS=${TEST_MIGRATIONS}
  else
    MIGRATIONS=$(find . -name "*.ddl.up.sql" -o -name "*.all.dml.sql" -o -name "*.${ENV_ID}.dml.sql" -o -name "*.${ENV_ID}.*.dml.sql")
  fi

  if [ -z "${MIGRATIONS}" ]; then
    log "No migrations to process"
    else
      log "Processing migrations (unsorted) '${MIGRATIONS}'"
      # Apply 'basename' THEN apply 'sort' THEN convert newlines to spaces
      # -> 'sort' must come last
      # -> 'xargs -n 1' because 'basename'/'sort' cannot take more than one item as param
      MIGRATIONS=$(echo ${MIGRATIONS} | xargs -n1 basename | xargs -n1 | sort -s | xargs)
  fi

  log "MIGRATIONS=${MIGRATIONS}"

  MIGRATION_COUNT=$(echo "${MIGRATIONS}" | wc -w | tr -d '[:space:]')
  if [ -z "${MIGRATION_COUNT}" ]; then
    log "No migrations available"
    MIGRATION_COUNT=0
  fi
  log "MIGRATION_COUNT=${MIGRATION_COUNT}"

  MIGRATIONS_DDL=""
  MIGRATIONS_DML=""

  for i in ${MIGRATIONS}
  do
    log "  Checking ${i}"
    if [ ${i: -11} == ".ddl.up.sql" ]; then
      MIGRATIONS_DDL+="${i} "
    elif [ ${i: -8} == ".dml.sql" ]; then
      MIGRATIONS_DML+="${i} "
    else
      log "  Skipping ${i}"
    fi
  done

  if [ -z "${MIGRATIONS_DDL}" ]; then
    log "No DDL migrations available"
    MIGRATION_COUNT_DDL=0
  fi
  if [ -z "${MIGRATIONS_DML}" ]; then
    log "No DML migrations available"
    MIGRATION_COUNT_DML=0
  fi

  MIGRATION_COUNT_DDL=$(echo "${MIGRATIONS_DDL}" | wc -w | tr -d '[:space:]')
  MIGRATION_COUNT_DML=$(echo "${MIGRATIONS_DML}" | wc -w | tr -d '[:space:]')

  log "MIGRATIONS_DDL=${MIGRATIONS_DDL}"
  log "MIGRATION_COUNT_DDL=${MIGRATION_COUNT_DDL}"

  log "MIGRATIONS_DML=${MIGRATIONS_DML}"
  log "MIGRATION_COUNT_DML=${MIGRATION_COUNT_DML}"

  log "LEAVE fn_count_migrations..."
  echo
}

fn_last_migration ()
{
  echo
  log "ENTER fn_last_migration..."

  if [ "${TEST_MODE}" == true ]; then
    LAST_MIGRATION_DDL=$(echo "${TEST_LAST_MIGRATION_DDL}" | awk 'END{print $NF}')
    LAST_MIGRATION_DML=$(echo "${TEST_LAST_MIGRATION_DML}" | awk 'END{print $NF}')

  else
    log "Inspecting table SchemaMigrations for last revision"
    fn_exit_on_error_off
    SELECT_LAST_MIGRATION_DDL=$(gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="SELECT Version from SchemaMigrations" --format=json)
    fn_exit_on_error
    echo "SELECT_LAST_MIGRATION_DDL=${SELECT_LAST_MIGRATION_DDL}"
    LAST_MIGRATION_DDL=$(echo ${SELECT_LAST_MIGRATION_DDL} | jq -r '.rows | .[0] | .[0]')
    echo "LAST_MIGRATION_DDL=${LAST_MIGRATION_DDL}"

    if [ -z "${LAST_MIGRATION_DDL}" ]; then
      log "PLEASE IGNORE ERROR: DDL migration tracking table does not exist, table will be created if necessary"
    else
      log "DDL migration tracking table exists"
    fi

    log "Inspecting table DataMigrations for last revision"
    fn_exit_on_error_off
    SELECT_LAST_MIGRATION_DML=$(gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="SELECT Version from DataMigrations" --format=json)
    fn_exit_on_error
    echo "SELECT_LAST_MIGRATION_DML=${SELECT_LAST_MIGRATION_DML}"
    LAST_MIGRATION_DML=$(echo ${SELECT_LAST_MIGRATION_DML} | jq -r '.rows | .[0] | .[0]')
    echo "LAST_MIGRATION_DML=${LAST_MIGRATION_DML}"

    if [ -z "${LAST_MIGRATION_DML}" ]; then
      log "PLEASE IGNORE ERROR: DML migration tracking table does not exist, table will be created if necessary"
    else
      log "DML migration tracking table exists"
    fi
  fi

  fn_exit_on_error_off
  if [ -z "${LAST_MIGRATION_DDL}" -o "${LAST_MIGRATION_DDL}" == "null" ]; then
    log "No DDL migrations applied"
    LAST_MIGRATION_DDL=0
  fi
  if [ -z "${LAST_MIGRATION_DML}" -o "${LAST_MIGRATION_DML}" == "null" ]; then
    log "No DML migrations applied"
    LAST_MIGRATION_DML=0
  fi
  fn_exit_on_error

  log "LAST_MIGRATION_DDL=${LAST_MIGRATION_DDL}"
  log "LAST_MIGRATION_DML=${LAST_MIGRATION_DML}"

  if [ ${LAST_MIGRATION_DDL} -gt ${LAST_MIGRATION_DML} ]; then
    LAST_MIGRATION=${LAST_MIGRATION_DDL}
  else
    LAST_MIGRATION=${LAST_MIGRATION_DML}
  fi
  log "LAST_MIGRATION=${LAST_MIGRATION}"

  log "LEAVE fn_last_migration..."
  echo
}

fn_outstanding_migrations ()
{
  echo
  log "ENTER fn_outstanding_migrations..."

  HAS_OUTSTANDING_DML_MIGRATIONS=false
  OUTSTANDING_MIGRATIONS=""
  OUTSTANDING_MIGRATIONS_COUNT=0

  for i in ${MIGRATIONS_DDL}
  do
    log "  Checking DDL ${i}"
    n=$(echo ${i} | cut -c1-3 | awk 'END{print $NF}')
    log "    with prefix ${n}"
    if [ ${n} -gt ${LAST_MIGRATION} ]; then
      OUTSTANDING_MIGRATIONS+="${i} "
      OUTSTANDING_MIGRATIONS_COUNT=$((OUTSTANDING_MIGRATIONS_COUNT+1))
    fi
  done

  for i in ${MIGRATIONS_DML}
  do
    log "  Checking DML ${i}"
    n=$(echo ${i} | cut -c1-3 | awk 'END{print $NF}')
    log "    with prefix ${n}"
    if [ ${n} -gt ${LAST_MIGRATION} ]; then
      OUTSTANDING_MIGRATIONS+="${i} "
      OUTSTANDING_MIGRATIONS_COUNT=$((OUTSTANDING_MIGRATIONS_COUNT+1))
      HAS_OUTSTANDING_DML_MIGRATIONS=true
    fi
  done

  OUTSTANDING_MIGRATIONS=$(echo ${OUTSTANDING_MIGRATIONS} | tr " " "\n" | sort -s | tr "\n" " ")

  log "OUTSTANDING_MIGRATIONS=${OUTSTANDING_MIGRATIONS}"
  log "OUTSTANDING_MIGRATIONS_COUNT=${OUTSTANDING_MIGRATIONS_COUNT}"

  log "LEAVE fn_outstanding_migrations..."
  echo
}

fn_apply_all_ddl ()
{
  echo
  log "ENTER fn_apply_all_ddl..."

  if [ "${TEST_MODE}" == true ]; then
    log "Skipping"
  else
    migrate -path . -database spanner://projects/${GCP_PROJECT_ID}/instances/${SPANNER_INSTANCE_ID}/databases/${SPANNER_DATABASE_ID} up
  fi

  log "LEAVE fn_apply_all_ddl..."
  echo
}

fn_apply_ddl ()
{
  echo
  log "ENTER fn_apply_ddl..."

  log "Applying revision ${2} from file ${1}"

  if [ "${TEST_MODE}" == true ]; then
    log "Skipping"
  else
    migrate -path . -database spanner://projects/${GCP_PROJECT_ID}/instances/${SPANNER_INSTANCE_ID}/databases/${SPANNER_DATABASE_ID} up 1
  fi

  log "LEAVE fn_apply_ddl..."
  echo
}

fn_apply_dml ()
{
  echo
  log "ENTER fn_apply_dml..."

  log "Applying revision ${2} from file ${1}"

  if [ ${2} -eq ${LAST_MIGRATION_DML} ]; then
    log "Cannot set revision ${2} in DataMigrations for pending DML migration ${1} since it has already been applied. Do you have 2 DML files with the same revision for the same environmnet?"
    exit_with_code 1
  fi

  if [ "${TEST_MODE}" == true ]; then
    echo "${TEST_DML}" > "${1}.tmp"
    awk '{printf "%s ",$0} END {print ""}' "${1}.tmp" | awk -F';' '{$1=$1}1' OFS=';\n' > "${1}.tmp.tmp"
    while IFS= read -r line; do
      if [[ -z "${line// }" ]]; then
        log "  Skipping empty line..."
      else
        log "Skipping ${line}"
      fi
    done < "${1}.tmp.tmp"
    rm -f "${1}.tmp" "${1}.tmp.tmp"
  else
    log "Setting revision ${2} as dirty in DataMigrations for pending DML migration ${1}"
    gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="INSERT INTO DataMigrations (Version, Dirty) VALUES (${2}, true)" --format=json

    awk '{printf "%s ",$0} END {print ""}' "${1}" | awk -F';' '{$1=$1}1' OFS=';\n' > "${1}.tmp"
    while IFS= read -r line; do
      if [[ -z "${line// }" ]]; then
        log "  Skipping empty line..."
      else
        log "  Running: ${line}"
        gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="${line}" --format=json
      fi
    done < "${1}.tmp"
    rm -f "${1}.tmp"

    log "Setting revision ${2} in DataMigrations as NOT dirty for completed DML migration ${1}"
    gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="UPDATE DataMigrations SET Dirty=false WHERE Version=${2}" --format=json

    if [ ${LAST_MIGRATION_DML} -gt 0 ]; then
      log "Removing revision ${LAST_MIGRATION_DML} in DataMigrations for superseded DML migration"
      gcloud spanner databases execute-sql ${SPANNER_DATABASE_ID} --instance=${SPANNER_INSTANCE_ID} --sql="DELETE FROM DataMigrations WHERE Version=${LAST_MIGRATION_DML}" --format=json
    else
      log "This is the first DML so there is no superseded DML migration to remove"
    fi

    log "Recording in memory the last DML revision ${2} so if there are multiple DML revisions to apply this function can still do some sanity checks before it starts work"
    LAST_MIGRATION_DML=${2}
  fi

  log "LEAVE fn_apply_dml..."
  echo
}

fn_apply_migrations ()
{
  echo
  log "ENTER fn_apply_migrations..."

  log "OUTSTANDING_MIGRATIONS=${OUTSTANDING_MIGRATIONS}"

  for i in ${OUTSTANDING_MIGRATIONS}
  do
    log "  Processing ${i}"
    n=$(echo ${i} | cut -c1-3 | awk 'END{print $NF}')
    log "    with prefix ${n}"

    if [ ${i: -8} == ".dml.sql" ]; then
      fn_process_tmpl ${i}
      DML_FILE=$(basename ${i} .dml.sql).tmp.dml.sql
      fn_apply_dml ${DML_FILE} ${n}
    else
      fn_apply_ddl ${i} ${n}
    fi
  done

  log "LEAVE fn_apply_migrations..."
  echo
}
# <- FUNCTIONS ----------------------------------------


fn_count_migrations

if [ ${MIGRATION_COUNT} -eq 0 ]; then
  log "No migrations available"
  exit_with_code 0
fi

if [ ${MIGRATION_COUNT_DML} -eq 0 ]; then
  log "No DML migrations available"
  fn_apply_all_ddl
  exit_with_code 0
fi

fn_last_migration

fn_outstanding_migrations

if [ "${HAS_OUTSTANDING_DML_MIGRATIONS}" = true ]; then
  log "Outstanding DML migrations available so will now make sure the DML table has been created"
  fn_create_dml_table_if_necessary
fi

if [ ${OUTSTANDING_MIGRATIONS_COUNT} -eq 0 ]; then
  log "No migrations needed"
  exit_with_code 0
fi

fn_apply_migrations

exit_with_code 0

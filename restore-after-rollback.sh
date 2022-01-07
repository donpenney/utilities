#!/bin/bash
#
# This script manages post-rollback recovery.
#

declare PROG=
PROG=$(basename "$0")

function usage {
    cat <<ENDUSAGE
${PROG}: Runs post-rollback restore procedure

Options:
    --container-backup <dir>
    --cluster-backup <dir>
    --etc-backup <dir>
    --force
ENDUSAGE
    exit 1
}

function get_container_id {
    local name=$1
    crictl ps | awk -v name="${name}" '{if ($(NF-2) == name) {print $1; exit 0}}'
}

function get_container_state {
    local name=$1
    crictl ps | awk -v name="${name}" '{if ($(NF-2) == name) {print $(NF-3); exit 0}}'
}

function get_current_revision {
    local name=$1
    oc get "${name}" -o=jsonpath='{.items[0].status.nodeStatuses[0].currentRevision}{"\n"}'
}

function get_latest_available_revision {
    local name=$1
    oc get "${name}" -o=jsonpath='{.items[0].status.latestAvailableRevision}{"\n"}'
}

function trigger_new_revision {
    local name=$1
    oc patch "${name}" cluster -p='{"spec": {"forceRedeploymentReason": "recovery-'"$( date --rfc-3339=ns )"'"}}' --type=merge
    if [ $? -ne 0 ]; then
        echo "Failed to patch ${name}. Please investigate" >&2
        exit 1
    fi
}

declare BU_DIR_CLUSTER=
declare BU_DIR_CONTAINER=
declare BU_DIR_ETC=

LONGOPTS="cluster-backup:,container-backup:,etc-backup:"
OPTS=$(getopt -o h --long "${LONGOPTS}" --name "$0" -- "$@")

if [ $? -ne 0 ]; then
    usage
    exit 1
fi

eval set -- "${OPTS}"

while :; do
    case "$1" in
        --cluster-backup)
            BU_DIR_CLUSTER=$2
            shift 2
            ;;
        --container-backup)
            BU_DIR_CONTAINER=$2
            shift 2
            ;;
        --etc-backup)
            BU_DIR_ETC=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [ -z "${KUBECONFIG}" ] || [ ! -r "${KUBECONFIG}" ]; then
    echo "Please provide kubeconfig location in KUBECONFIG env variable" >&2
    exit 1
fi

if [ -z "${BU_DIR_CLUSTER}" ] || [ ! -d "${BU_DIR_CLUSTER}" ] || \
        [ -z "${BU_DIR_CONTAINER}" ] || [ ! -d "${BU_DIR_CONTAINER}" ] || \
        [ -z "${BU_DIR_ETC}" ] || [ ! -d "${BU_DIR_ETC}" ]; then
    echo "Please specify required directories with --cluster-backup, --container-backup, and --etc-backup options" >&2
    exit 1
fi

# Check for current cluster version
ORIG_CLUSTER_VERSION=$(oc get clusterversions.config.openshift.io -o=jsonpath='{.items[0].status.desired.version}')
if [ -z "${ORIG_CLUSTER_VERSION}" ]; then
    echo "Failed to get cluster version. Please verify kubeconfig setup." >&2
    exit 1
fi

# Get current container IDs
ORIG_ETCD_CONTAINER_ID=$(get_container_id etcd)
if [ -z "${ORIG_ETCD_CONTAINER_ID}" ]; then
    echo "Failed to get etcd container id" >&2
    exit 1
fi

ORIG_ETCD_OPERATOR_CONTAINER_ID=$(get_container_id etcd-operator)
if [ -z "${ORIG_ETCD_OPERATOR_CONTAINER_ID}" ]; then
    echo "Failed to get etcd-operator container id" >&2
    exit 1
fi

# Restore container images
echo "##### $(date -u): Restoring container images"
for id in $(find ${BU_DIR_CONTAINER} -mindepth 1 -maxdepth 2 -type d); do
    /usr/bin/skopeo copy dir:$id containers-storage:local/$(basename $id)
done
echo "##### $(date -u): Completed restoring container images"

# Restore /etc content
echo "##### $(date -u): Restoring /etc content"
rsync -avc --delete --no-t --exclude-from ${BU_DIR_ETC}/etc.exclude.list ${BU_DIR_ETC}/etc/ /etc/
if [ $? -ne 0 ]; then
    echo "$(date -u): Failed to restore /etc content" >&2
    exit 1
fi
systemctl daemon-reload
echo "##### $(date -u): Completed restoring /etc content"

# Restore cluster
echo "##### $(date -u): Restoring cluster"
time /usr/local/bin/cluster-restore.sh ${BU_DIR_CLUSTER}
if [ $? -ne 0 ]; then
    echo "$(date -u): Failed to restore cluster" >&2
    exit 1
fi

echo "##### $(date -u): Restarting kubelet.service"
time systemctl restart kubelet.service

echo "##### $(date -u): Restarting crio.service"
time systemctl restart crio.service

echo "##### $(date -u): Waiting for etcd container to restart"
TIMEOUT=$((SECONDS+900))
while [ ${SECONDS} -lt ${TIMEOUT} ]; do
    cur_id=$(get_container_id etcd)
    cur_state=$(get_container_state etcd)
    if [ -n "${cur_id}" ] && [ "${cur_id}" != "${ORIG_ETCD_CONTAINER_ID}" ] && [ "${cur_state}" = "Running" ]; then
        break
    fi
done

if [ "$(get_container_state etcd)" != "Running" ]; then
    echo "etcd container is not Running. Please investigate" >&2
    exit 1
fi
echo "##### $(date -u): etcd container restarted"

echo "##### $(date -u): Waiting for required operators to restart"

required_operators="etcd-operator kube-apiserver-operator kube-controller-manager-operator kube-scheduler-operator-container"
TIMEOUT=$((SECONDS+3600)) # Wait up to an hour total
time for name in ${required_operators}; do
    echo -n "Checking ${name}..."
    while  [ $SECONDS -lt $TIMEOUT ]; do
        cur_state=$(get_container_state "${name}")
        if [ "${cur_state}" = "Running" ]; then
            echo -e "\n${name} is running"
            break
        fi
        echo -n "." && sleep 10
    done

    cur_state=$(get_container_state "${name}")
    if [ "${cur_state}" != "Running" ]; then
        echo -e "\n${name} is not running. Please investigate further."
    fi
done

echo "##### $(date -u): Required operators have restarted"

echo "##### $(date -u): Triggering redeployments"
redeployments="etcd kubeapiserver kubecontrollermanager kubescheduler"
time for name in ${redeployments}; do
    starting_rev=$(get_current_revision "${name}")
    starting_latest_rev=$(get_latest_available_revision "${name}")
    if [ -z "${starting_rev}" ] || [ -z "${starting_latest_rev}" ]; then
        echo "Failed to get info for ${name}"
        break
    fi

    expected_rev=$((starting_latest_rev+1))

    echo "Patching ${name}. Starting rev is ${starting_rev}. Expected new rev is ${expected_rev}."
    trigger_new_revision "${name}"

    TIMEOUT=$((SECONDS+1800)) # 15 minutes
    while [ $SECONDS -lt $TIMEOUT ]; do
        cur_rev=$(get_current_revision "${name}")
        if [ -z "${cur_rev}" ]; then
            echo -n "."; sleep 10
            continue # intermittent API failure
        fi

        if [[ ${cur_rev} == ${expected_rev} ]]; then
            echo -e "\n${name} redeployed successfully"
            break
        fi
        echo -n "."; sleep 10
    done

    cur_rev=$(get_current_revision "${name}")
    if [[ ${cur_rev} != ${expected_rev} ]]; then
        echo "Failed to redeploy ${name}. Please investigate" >&2
        exit 1
    fi
done


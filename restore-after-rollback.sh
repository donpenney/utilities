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
    --force:                  Skip ostree deployment check
ENDUSAGE
    exit 1
}

function display_current_status {
    echo "##### $(date -u): Displaying current status"

    echo "##### $(date -u): oc adm upgrade && oc get co && oc get nodes -o wide && oc get mcp"
    oc adm upgrade && oc get co && oc get nodes -o wide && oc get mcp
    echo "##### $(date -u): Done"
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
    oc get "${name}" -o=jsonpath='{.items[0].status.nodeStatuses[0].currentRevision}{"\n"}' 2>/dev/null
}

function get_latest_available_revision {
    local name=$1
    oc get "${name}" -o=jsonpath='{.items[0].status.latestAvailableRevision}{"\n"}' 2>/dev/null
}

function wait_for_container_restart {
    local name=$1
    local orig_id=$2
    local timeout=
    timeout=$((SECONDS+$3))

    local cur_id=
    local cur_state=

    echo "##### $(date -u): Waiting for ${name} container to restart"

    while [ ${SECONDS} -lt ${timeout} ]; do
        cur_id=$(get_container_id "${name}")
        cur_state=$(get_container_state "${name}")
        if [ -n "${cur_id}" ] && \
                [ "${cur_id}" != "${orig_id}" ] && \
                [ "${cur_state}" = "Running" ]; then
            break
        fi
        echo -n "." && sleep 10
    done

    if [ "$(get_container_state ${name})" != "Running" ]; then
        echo -e "\n$(date -u): ${name} container is not Running. Please investigate" >&2
        exit 1
    fi

    echo -e "\n${name} is running"
    echo "##### $(date -u): ${name} container restarted"
}

function trigger_redeployment {
    local name=$1
    local timeout=
    timeout=$((SECONDS+$2))

    local starting_rev=
    local starting_latest_rev=
    local cur_rev=
    local expected_rev=

    echo "##### $(date -u): Triggering ${name} redeployment"

    starting_rev=$(get_current_revision "${name}")
    starting_latest_rev=$(get_latest_available_revision "${name}")
    if [ -z "${starting_rev}" ] || [ -z "${starting_latest_rev}" ]; then
        echo "Failed to get info for ${name}"
        exit 1
    fi

    expected_rev=$((starting_latest_rev+1))

    echo "Patching ${name}. Starting rev is ${starting_rev}. Expected new rev is ${expected_rev}."
    oc patch "${name}" cluster -p='{"spec": {"forceRedeploymentReason": "recovery-'"$( date --rfc-3339=ns )"'"}}' --type=merge
    if [ $? -ne 0 ]; then
        echo "Failed to patch ${name}. Please investigate" >&2
        exit 1
    fi

    while [ $SECONDS -lt $timeout ]; do
        cur_rev=$(get_current_revision "${name}")
        if [ -z "${cur_rev}" ]; then
            echo -n "."; sleep 10
            continue # intermittent API failure
        fi

        if [[ ${cur_rev} -ge ${expected_rev} ]]; then
            echo -e "\n${name} redeployed successfully: revision ${cur_rev}"
            break
        fi
        echo -n "."; sleep 10
    done

    cur_rev=$(get_current_revision "${name}")
    if [[ ${cur_rev} -lt ${expected_rev} ]]; then
        echo "Failed to redeploy ${name}. Please investigate" >&2
        exit 1
    fi

    echo "##### $(date -u): Completed ${name} redeployment"
}

declare BACKUP_DIR="/var/recovery"
declare RESTART_TIMEOUT=900 # 15 minutes
declare REDEPLOYMENT_TIMEOUT=900 # 15 minutes
declare SKIP_DEPLOY_CHECK="no"

LONGOPTS="dir:,force"
OPTS=$(getopt -o h --long "${LONGOPTS}" --name "$0" -- "$@")

if [ $? -ne 0 ]; then
    usage
    exit 1
fi

eval set -- "${OPTS}"

while :; do
    case "$1" in
        --dir)
            BACKUP_DIR=$2
            shift 2
            ;;
        --force)
            SKIP_DEPLOY_CHECK="yes"
            shift
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

if [ ! -d "${BACKUP_DIR}/cluster" ] || \
        [ ! -d "${BACKUP_DIR}/containers" ] || \
        [ ! -d "${BACKUP_DIR}/etc" ] || \
        [ ! -d "${BACKUP_DIR}/usrlocal" ]; then
    echo "Required backup content not found in ${BACKUP_DIR}" >&2
    exit 1
fi

if ! ostree admin status | grep -A 3 '^\*' | grep -q 'Pinned: yes'; then
    if [ "${SKIP_DEPLOY_CHECK}" = "yes" ]; then
        echo "Warning: Active ostree deployment is not pinned and should be rolled back."
    else
        echo "Active ostree deployment is not pinned and should be rolled back." >&2
        exit 1
    fi
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

ORIG_KUBE_APISERVER_OPERATOR_CONTAINER_ID=$(get_container_id kube-apiserver-operator)
if [ -z "${ORIG_KUBE_APISERVER_OPERATOR_CONTAINER_ID}" ]; then
    echo "Failed to get kube-apiserver-operator container id" >&2
    exit 1
fi

ORIG_KUBE_CONTROLLER_MANAGER_OPERATOR_CONTAINER_ID=$(get_container_id kube-controller-manager-operator)
if [ -z "${ORIG_KUBE_CONTROLLER_MANAGER_OPERATOR_CONTAINER_ID}" ]; then
    echo "Failed to get kube-controller-manager-operator container id" >&2
    exit 1
fi

ORIG_KUBE_SCHEDULER_OPERATOR_CONTAINER_ID=$(get_container_id kube-scheduler-operator-container)
if [ -z "${ORIG_KUBE_SCHEDULER_OPERATOR_CONTAINER_ID}" ]; then
    echo "Failed to get kube-scheduler-operator-container container id" >&2
    exit 1
fi

display_current_status

echo "##### $(date -u): Pausing machine config"
oc patch --type=merge --patch='{"spec":{"paused":true}}' machineconfigpool/master
oc patch --type=merge --patch='{"spec":{"paused":true}}' machineconfigpool/worker

# Restore container images
echo "##### $(date -u): Restoring container images"
time for id in $(find ${BACKUP_DIR}/containers -mindepth 1 -maxdepth 2 -type d); do
    /usr/bin/skopeo copy dir:$id containers-storage:local/$(basename $id)
done
echo "##### $(date -u): Completed restoring container images"

# Restore /usr/local content
echo "##### $(date -u): Restoring /usr/local content"
time rsync -avc --delete --no-t ${BACKUP_DIR}/usrlocal/ /usr/local/
if [ $? -ne 0 ]; then
    echo "$(date -u): Failed to restore /usr/local content" >&2
    exit 1
fi
echo "##### $(date -u): Completed restoring /etc content"

# Restore /etc content
echo "##### $(date -u): Restoring /etc content"
time rsync -avc --delete --no-t --exclude-from ${BACKUP_DIR}/etc.exclude.list ${BACKUP_DIR}/etc/ /etc/
if [ $? -ne 0 ]; then
    echo "$(date -u): Failed to restore /etc content" >&2
    exit 1
fi
echo "##### $(date -u): Completed restoring /etc content"

if [ -f ${BACKUP_DIR}/extras.tgz ]; then
    echo "##### $(date -u): Restoring extra content"
    tar xzf ${BACKUP_DIR}/extras.tgz -C /
    if [ $? -ne 0 ]; then
        echo "$(date -u): Failed to restore extra content" >&2
        exit 1
    fi
    echo "##### $(date -u): Completed restoring extra content"
fi

systemctl daemon-reload

# Restore cluster
echo "##### $(date -u): Restoring cluster"
time /usr/local/bin/cluster-restore.sh ${BACKUP_DIR}/cluster
if [ $? -ne 0 ]; then
    echo "$(date -u): Failed to restore cluster" >&2
    exit 1
fi

echo "##### $(date -u): Restarting kubelet.service"
time systemctl restart kubelet.service

echo "##### $(date -u): Restarting crio.service"
time systemctl restart crio.service

echo "##### $(date -u): Waiting for required container restarts"

time wait_for_container_restart etcd "${ORIG_ETCD_CONTAINER_ID}" ${RESTART_TIMEOUT}
time wait_for_container_restart etcd-operator "${ORIG_ETCD_OPERATOR_CONTAINER_ID}" ${RESTART_TIMEOUT}
time wait_for_container_restart kube-apiserver-operator "${ORIG_KUBE_APISERVER_OPERATOR_CONTAINER_ID}" ${RESTART_TIMEOUT}
time wait_for_container_restart kube-controller-manager-operator "${ORIG_KUBE_CONTROLLER_MANAGER_OPERATOR_CONTAINER_ID}" ${RESTART_TIMEOUT}
time wait_for_container_restart kube-scheduler-operator-container "${ORIG_KUBE_SCHEDULER_OPERATOR_CONTAINER_ID}" ${RESTART_TIMEOUT}

echo "##### $(date -u): Required containers have restarted"

echo "##### $(date -u): Triggering redeployments"

time trigger_redeployment etcd ${REDEPLOYMENT_TIMEOUT}
time trigger_redeployment kubeapiserver ${REDEPLOYMENT_TIMEOUT}
time trigger_redeployment kubecontrollermanager ${REDEPLOYMENT_TIMEOUT}
time trigger_redeployment kubescheduler ${REDEPLOYMENT_TIMEOUT}

echo "##### $(date -u): Redeployments complete"

echo "##### $(date -u): Recovery complete"

display_current_status


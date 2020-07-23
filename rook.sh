#!/bin/bash

RCFILE="/usr/lib/supportconfig/resources/scplugin.rc"
CENSORED='<<CENSORED BY SUPPORTCONFIG PLUGIN>>'

[ -s $RCFILE ] && . $RCFILE || { echo "ERROR: Initializing resource file: $RCFILE"; exit 1; }

source rook-helpers.sh

LOG=".log-dir"
mkdir --parents ${LOG:?}
mkdir $LOG/ceph/


#############################################################
KUBECTL="${KUBECTL:-kubectl}"
ROOK_NAMESPACE="${ROOK_NAMESPACE:-rook-ceph}"
KUBECTL_ROOK="$KUBECTL --namespace $ROOK_NAMESPACE"


#############################################################
section_header "Kubernetes cluster information"
KUBELOG=$LOG/ceph/kube
mkdir $KUBELOG/

if ! [ -x "$(command -v $KUBECTL)" ]; then
  echo "ERROR: kubectl does not exist"
  exit 1 # cannot collect any Rook info w/o kubectl
fi

if ! plugin_command "$KUBECTL version" &> $KUBELOG/kube-version; then
  echo "ERROR: kubectl cannot connect to a Kubernetes cluster"
  exit 1 # cannot collect any Rook info w/o a K8s cluster connection
fi

{
  section_header "nodes overview"
  plugin_command "$KUBECTL get nodes --show-labels" 2>&1
  resource_detail "" nodes 2>&1
} >> $KUBELOG/nodes

resource_overview "" namespaces >> $KUBELOG/namespaces 2>&1

resource_overview_and_detail "" crds >> $KUBELOG/crds 2>&1


#############################################################
section_header "Rook-Ceph cluster information"
ROOKLOG=$LOG/ceph/rook
mkdir $ROOKLOG/

if ! $KUBECTL get namespaces | grep -q "^$ROOK_NAMESPACE[[:space:]]"; then
  echo "ERROR: Rook namespace '$ROOK_NAMESPACE' does not exist"
  exit 1 # cannot collect any Rook info if no Rook cluster exists
fi

# ONLY SUPPORTS ENVIRONMENTS WHERE ROOK OPERATOR AND CEPH CLUSTER ARE IN SAME NAMESPACE

plugin_message "Collecting Kubernetes Resource information for cluster $ROOK_NAMESPACE"
plugin_message "" # newline
resource_overview_and_detail "$ROOK_NAMESPACE" pods >> $ROOKLOG/pods 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" replicasets >> $ROOKLOG/replicasets 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" deployments >> $ROOKLOG/deployments 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" "jobs" >> $ROOKLOG/jobs 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" daemonsets >> $ROOKLOG/daemonsets 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" configmaps >> $ROOKLOG/configmaps 2>&1
# TODO: does detail on secrets reveal too much secure info about a customer?
resource_overview "$ROOK_NAMESPACE" secrets >> $ROOKLOG/secrets 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" services >> $ROOKLOG/services 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" clusterroles >> $ROOKLOG/clusterroles 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" clusterrolebindings >> $ROOKLOG/clusterrolebindings 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" roles >> $ROOKLOG/roles 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" rolebindings >> $ROOKLOG/rolebindings 2>&1
resource_overview_and_detail "$ROOK_NAMESPACE" serviceaccounts >> $ROOKLOG/serviceaccounts 2>&1

ROOK_SHELL="${KUBECTL_ROOK:?} exec -t deploy/rook-ceph-operator --"

plugin_message "Collecting Rook-Ceph Operator information for cluster $ROOK_NAMESPACE"
plugin_message "" # newline
{
  selector="--selector 'app=rook-ceph-operator'"
  section_header "Rook operator Pod details for cluster $ROOK_NAMESPACE"
  plugin_command "$KUBECTL_ROOK get pod $selector --output=yaml" 2>&1
  plugin_command "$KUBECTL_ROOK get replicaset $selector --output=yaml" 2>&1
  plugin_command "$KUBECTL_ROOK get deployment rook-ceph-operator --output=yaml" 2>&1
  section_header "Rook operator internal details for cluster $ROOK_NAMESPACE"
  plugin_command "$ROOK_SHELL rook version" 2>&1
  plugin_command "$ROOK_SHELL ls --recursive /var/lib/rook" 2>&1
  plugin_command "$ROOK_SHELL cat /var/lib/rook/*/*.config" 2>&1
  # TODO: does this reveal too much secure info about a customer?
  # plugin_command "$ROOK_SHELL cat /var/lib/rook/*/*.keyring" 2>&1
  plugin_command "$ROOK_SHELL ls --recursive /etc/ceph" 2>&1
} >> $ROOKLOG/operator

plugin_command "$ROOK_SHELL rook version" &> $ROOKLOG/rook-version


plugin_message "Collecting Rook-Ceph Custom Resources for cluster $ROOK_NAMESPACE"

CRLOG=$ROOKLOG/custom-resources
mkdir $CRLOG

crds_json="$($KUBECTL get crds --output=json)"
crds="$(echo "$crds_json" | jq -r '.items[].metadata.name')"
for crd in $crds; do
  if [[ "$crd" == *.rook.io ]] || [[ "$crd" == *.objectbucket.io ]]; then
    resources="$($KUBECTL_ROOK get $crd --output=name)"
    for resource in $resources; do
      # each resource is, e.g., cephcluster.rook.io/rook-ceph
      logfile="${resource//\//_}" # replace '/' char with '_' for log file name
      plugin_message "  found Custom Resource $resource"
      resource_overview_and_detail "$ROOK_NAMESPACE" "$resource" >> $CRLOG/$logfile
    done
  fi
done
plugin_message "" # newline


#############################################################
section_header "Rook-Ceph Pod logs"
PODLOG=$ROOKLOG/pod-logs
mkdir $PODLOG

pods="$($KUBECTL_ROOK get pods --output=name)"
for pod in $pods; do
  pod=${pod##pod/} # --output=names gives names in format pod/<pod-name>; strip "pod/" from start
  plugin_message "Collecting logs from Pod $pod"
  pod_logs $ROOK_NAMESPACE $pod >> $PODLOG/$pod-logs
done
plugin_message "" # newline


#############################################################
section_header "Ceph cluster logs"
PODLOG=$ROOKLOG/pods

# Determine which Rook image the cluster is using for the collector helper
operator_json="$($KUBECTL_ROOK get deployment rook-ceph-operator --output=json)"
ROOK_IMAGE="$(echo "$operator_json" | jq -r '.spec.template.spec.containers[0].image')"
plugin_message "ROOK_IMAGE=$ROOK_IMAGE"
plugin_message "" # newline

source rook-collector-helper.sh
if ! start_collector_helper; then
  exit 1 # need collector to get more info than this; fail if we can't continue
fi
# always try to remove the collector helper on script exit
trap stop_collector_helper EXIT

plugin_command "$COLLECTOR_SHELL ceph status"


#############################################################
# TODO: get disk layout of nodes?

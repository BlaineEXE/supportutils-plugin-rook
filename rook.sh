#!/bin/bash

RCFILE="/usr/lib/supportconfig/resources/scplugin.rc"
LOG_LINES=5000  # 0 means include the entire file
CENSORED='<<CENSORED BY SUPPORTCONFIG PLUGIN>>'

[ -s $RCFILE ] && . $RCFILE || { echo "ERROR: Initializing resource file: $RCFILE"; exit 1; }

LOG=".log-dir"
mkdir --parents ${LOG:?}
mkdir $LOG/ceph/


#############################################################
KUBECTL="${KUBECTL:-kubectl}"
ROOK_NAMESPACE="${ROOK_NAMESPACE:-rook-ceph}"
CLUSTERNAME="$ROOK_NAMESPACE"
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

plugin_command "$KUBECTL get nodes --show-labels" &> $KUBELOG/node-overview
plugin_command "$KUBECTL get nodes --output=yaml" &> $KUBELOG/node-detail

plugin_command "$KUBECTL get namespaces" &> $KUBELOG/namespaces

# not necessary b/c we get Rook CRDs later, but keep this in case Rook adds new CRDs we don't expect
plugin_command "$KUBECTL get crds" &> $KUBELOG/crds-overview
plugin_command "$KUBECTL get crds --output=yaml" &> $KUBELOG/crds-detail


#############################################################
section_header "Rook-Ceph cluster information"
ROOKLOG=$LOG/ceph/rook
mkdir $ROOKLOG/

if ! $KUBECTL get namespaces | grep -q "^$ROOK_NAMESPACE[[:space:]]"; then
  echo "ERROR: Rook namespace '$ROOK_NAMESPACE' does not exist"
  exit 1 # cannot collect any Rook info if no Rook cluster exists
fi

# get specifically Rook CRDs
# crds=$($KUBECTL get crds --output=name)
# for crd in $crds; do
#   if [[ "$crd" == *.rook.io ]] || [[ "$crd" == *.objectbucket.io ]]; then
#     echo "$crd" >> $ROOKLOG/crds-overview
#     plugin_command "$KUBECTL get $crd --output=yaml" >> $ROOKLOG/crds-detail 2>&1
#   fi
# done

plugin_command "$KUBECTL_ROOK get deployments" &> $ROOKLOG/deployment-overview
plugin_command "$KUBECTL_ROOK get deployments --output=yaml" &> $ROOKLOG/deployment-detail

plugin_command "$KUBECTL_ROOK get daemonsets" &> $ROOKLOG/daemonset-overview
plugin_command "$KUBECTL_ROOK get daemonsets --output=yaml" &> $ROOKLOG/daemonset-detail

plugin_command "$KUBECTL_ROOK get replicasets" &> $ROOKLOG/replicaset-overview
plugin_command "$KUBECTL_ROOK get replicasets --output=yaml" &> $ROOKLOG/replicaset-detail

plugin_command "$KUBECTL_ROOK get configmaps" &> $ROOKLOG/configmap-overview
plugin_command "$KUBECTL_ROOK get configmaps --output=yaml" &> $ROOKLOG/configmap-detail

plugin_command "$KUBECTL_ROOK get secrets" &> $ROOKLOG/secrets-overview
# TODO: does this reveal too much secure info about a customer?
# plugin_command "$KUBECTL_ROOK get secrets --output=yaml" &> $ROOKLOG/secrets-detail


selector="--selector 'app=rook-ceph-operator'"
plugin_command "$KUBECTL_ROOK get pod $selector --output=yaml" >> $ROOKLOG/operator
plugin_command "$KUBECTL_ROOK get replicaset $selector --output=yaml" >> $ROOKLOG/operator
plugin_command "$KUBECTL_ROOK get deployment rook-ceph-operator --output=yaml" >> $ROOKLOG/operator

ROOK_SHELL="${KUBECTL_ROOK:?} exec -t deploy/rook-ceph-operator --"

plugin_command "$ROOK_SHELL rook version" &> $ROOKLOG/operator
plugin_command "$ROOK_SHELL ls --recursive /var/lib/rook" &> $ROOKLOG/operator
plugin_command "$ROOK_SHELL cat /var/lib/rook/*/*.config" &> $ROOKLOG/operator
# TODO: does this reveal too much secure info about a customer?
# plugin_command "$ROOK_SHELL cat /var/lib/rook/*/*.keyring" &> $ROOKLOG/operator
plugin_command "$ROOK_SHELL ls --recursive /etc/ceph" &> $ROOKLOG/operator

plugin_command "$ROOK_SHELL rook version" &> $ROOKLOG/rook-version

operator_json="$($KUBECTL_ROOK get deployment rook-ceph-operator --output=json)"
ROOK_IMAGE="$(echo "$operator_json" | jq -r '.spec.template.spec.containers[0].image')"
plugin_message "ROOK_IMAGE=$ROOK_IMAGE"


source collector-helper.sh
if ! start_collector_helper; then
  exit 1 # need collector to get more info than this; fail if we can't continue
fi
# always try to remove the collector helper on script exit
trap stop_collector_helper EXIT

plugin_command "$COLLECTOR_SHELL ceph status"



#############################################################
# TODO: get disk layout of nodes?

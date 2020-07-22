#!/bin/bash

set -o nounset # fail if any vars here are unset

MANIFEST="$ROOKLOG/collector-helper.yaml"
COLLECTOR_LOG="$ROOKLOG/collector-helper"

cat > "$MANIFEST" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: supportutils-ses-rook-collector-helper
  # namespace was set to ROOK_NAMESPACE
  namespace: $ROOK_NAMESPACE
  labels:
    app: supportutils-ses-rook-collector-helper
spec:
  replicas: 1
  selector:
    matchLabels:
      app: supportutils-ses-rook-collector-helper
  template:
    metadata:
      labels:
        app: supportutils-ses-rook-collector-helper
    spec:
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: supportutils-ses-rook-collector-helper
        # image was set to ROOK_IMAGE
        image: $ROOK_IMAGE
        command: ["/tini"]
        args: ["-g", "--", "/usr/local/bin/toolbox.sh"]
        imagePullPolicy: IfNotPresent
        env:
          - name: ROOK_CEPH_USERNAME
            valueFrom:
              secretKeyRef:
                name: rook-ceph-mon
                key: ceph-username
          - name: ROOK_CEPH_SECRET
            valueFrom:
              secretKeyRef:
                name: rook-ceph-mon
                key: ceph-secret
        volumeMounts:
          - mountPath: /etc/ceph
            name: ceph-config
          - name: mon-endpoint-volume
            mountPath: /etc/rook
      volumes:
        - name: mon-endpoint-volume
          configMap:
            name: rook-ceph-mon-endpoints
            items:
            - key: data
              path: mon-endpoints
        - name: ceph-config
          emptyDir: {}
      tolerations:
        - key: "node.kubernetes.io/unreachable"
          operator: "Exists"
          effect: "NoExecute"
          tolerationSeconds: 5
EOF

COLLECTOR_SHELL="${KUBECTL_ROOK:?} exec -t deploy/supportutils-ses-rook-collector-helper --"

start_collector_helper() {
  plugin_command "$KUBECTL apply --filename='$MANIFEST'" >> $COLLECTOR_LOG 2>&1
  # wait for collector helper pod and container to be running and exec'able
  # usually starts in 2 seconds in testing
  TIMEOUT=${COLLECTOR_HELPER_TIMEOUT:-15} # seconds
  start=$SECONDS
  until plugin_command "$COLLECTOR_SHELL rook version" >> $COLLECTOR_LOG 2>&1; do
    if [[ $((SECONDS - start)) -gt $TIMEOUT ]]; then
      echo "ERROR: failed to start supportutils collector helper within $TIMEOUT seconds"
      dump_collector_helper_info
      stop_collector_helper
      return 1
    fi
  done
}

dump_collector_helper_info() {
  selector="--selector 'app=supportutils-ses-rook-collector-helper'"
  plugin_command "$KUBECTL_ROOK get pod $selector --output=yaml" >> $COLLECTOR_LOG 2>&1
  plugin_command "$KUBECTL_ROOK get replicaset $selector --output=yaml" >> $COLLECTOR_LOG 2>&1
  plugin_command "$KUBECTL_ROOK get deployment supportutils-ses-rook-collector-helper --output=yaml" >> $COLLECTOR_LOG 2>&1
}

stop_collector_helper() {
  plugin_command "$KUBECTL delete --filename='$MANIFEST'" >> $COLLECTOR_LOG 2>&1
}

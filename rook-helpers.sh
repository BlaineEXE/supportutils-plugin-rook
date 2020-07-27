#!/bin/bash

resource_overview() {
  local namespace="$1"
  local resource="$2"
  section_header "$resource overview"
  plugin_command "$KUBECTL --namespace=$namespace get $resource" 2>&1
}

resource_detail() {
  local namespace="$1"
  local resource="$2"
  section_header "$resource detail"
  # --output=json and --output=yaml have more information than 'kubectl describe'
  # output is cluttered, but sometimes critical information is missing from 'kubectl describe'
  # --output=json has same info as --output=yaml
  # use --output=json so that 'jq' can be used to inspect logs afterwards if desired
  plugin_command "$KUBECTL --namespace=$namespace get $resource --output=json" 2>&1
}

resource_overview_and_detail() {
  local namespace="$1"
  local resource="$2"
  resource_overview "$namespace" "$resource"
  resource_detail "$namespace" "$resource"
}

get_pod_containers() {
  local namespace="$1"
  local pod="$2"
  if ! pod_json="$($KUBECTL --namespace=$namespace get pod $pod --output=json)"; then
    return $? # error
  fi
  # print init containers in init order followed by app containers
  if [[ "$(echo "$pod_json" | jq -r '.spec.initContainers | length')" -gt 0 ]]; then
    echo "$pod_json" | jq -r '.spec.initContainers[].name'
  fi
  echo "$pod_json" | jq -r '.spec.containers[].name'
  return 0
}

pod_logs() {
  local namespace="$1"
  local pod="$2"
  if ! containers="$(get_pod_containers "$namespace" "$pod")"; then
    return $? # error
  fi
  # Log previous logs first since the likely workflow will be to read the logs bottom-up. Thus, we
  # want the bottommost log to be the most useful, which in almost all cases will be the single
  # application pod.
  section_header "previous logs for pod $pod"
  for container in $containers; do
    plugin_command "$KUBECTL --namespace=$namespace logs $pod --container=$container --previous" 2>&1
  done
  section_header "logs for pod $pod"
  for container in $containers; do
    plugin_command "$KUBECTL --namespace=$namespace logs $pod --container=$container" 2>&1
  done
}

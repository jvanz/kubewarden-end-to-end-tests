#!/usr/bin/env bats

# UI access:
# kubectl port-forward -n prometheus --address 0.0.0.0 svc/prometheus-operated 9090
# kubectl port-forward -n jaeger svc/my-open-telemetry-query 16686:16686

setup() {
  load common.bash
  wait_pods -n kube-system
}

@test "[OpenTelemetry] Install OpenTelemetry, Prometheus, Jaeger" {
    # OpemTelementry
    helm repo add --force-update open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
    helm upgrade -i --wait my-opentelemetry-operator open-telemetry/opentelemetry-operator \
        --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib" \
        -n open-telemetry --create-namespace

    # Prometheus
    helm repo add --force-update prometheus-community https://prometheus-community.github.io/helm-charts
    helm upgrade -i --wait  prometheus prometheus-community/kube-prometheus-stack \
        -n prometheus --create-namespace \
        --values $RESOURCES_DIR/opentelemetry-prometheus-values.yaml

    # Jaeger
    helm repo add --force-update jaegertracing https://jaegertracing.github.io/helm-charts
    helm upgrade -i --wait jaeger-operator jaegertracing/jaeger-operator \
        -n jaeger --create-namespace \
        --set rbac.clusterRole=true
    kubectl apply -f $RESOURCES_DIR/opentelemetry-jaeger.yaml
    wait_pods -n jaeger

    # Setup Kubewarden
    helm_up kubewarden-controller --reuse-values --values $RESOURCES_DIR/opentelemetry-kw-telemetry-values.yaml
    helm_up kubewarden-defaults --set "recommendedPolicies.enabled=True"
}

@test "[OpenTelemetry] Kubewarden containers have sidecars & metrics" {
    # Controller is restarted to get sidecar
    wait_pods -n kubewarden

    # Check all pods have sidecar (otc-container) - might take a minute to start
    retry "kubectl get pods -n kubewarden --field-selector=status.phase==Running -o json | jq -e '[.items[].spec.containers[1].name == \"otc-container\"] | all'"
    # Policy server service has the metrics ports
    kubectl get services -n kubewarden  policy-server-default -o json | jq -e '[.spec.ports[].name == "metrics"] | any'
    # Controller service has the metrics ports
    kubectl get services -n kubewarden kubewarden-controller-metrics-service -o json | jq -e '[.spec.ports[].name == "metrics"] | any'

    # Generate metric data
    kubectl run pod-privileged --image=registry.k8s.io/pause --privileged
    kubectl wait --for=condition=Ready pod pod-privileged
    kubectl delete --wait pod pod-privileged

    # Policy server & controller metrics should be available
    retry 'test $(get_metrics policy-server-default | wc -l) -gt 10'
    retry 'test $(get_metrics kubewarden-controller-metrics-service | wc -l) -gt 1'
}

@test "[OpenTelemetry] Audit scanner runs should generate metrics" {
    kubectl get cronjob -n $NAMESPACE audit-scanner

    # Launch unprivileged & privileged pods
    kubectl run nginx-unprivileged --image=nginx:alpine
    kubectl wait --for=condition=Ready pod nginx-unprivileged
    kubectl run nginx-privileged --image=registry.k8s.io/pause --privileged
    kubectl wait --for=condition=Ready pod nginx-privileged

    # Deploy some policy
    kubectl apply -f $RESOURCES_DIR/privileged-pod-policy.yaml
    apply_cluster_admission_policy $RESOURCES_DIR/namespace-label-propagator-policy.yaml

    run kubectl create job  --from=cronjob/audit-scanner testing  --namespace $NAMESPACE
    assert_output -p "testing created"
    kubectl wait --for=condition="Complete" job testing --namespace $NAMESPACE

    retry 'test $(get_metrics policy-server-default | grep protect | grep -oE "policy_name=\"[^\"]+" | sort -u | wc -l) -eq 2'
}

@test "[OpenTelemetry] Disabling telemetry should remove sidecars & metrics" {
    helm_up kubewarden-controller --set "telemetry.metrics.enabled=False" --set "telemetry.tracing.enabled=False" --reuse-values
    helm_up kubewarden-defaults --set "recommendedPolicies.enabled=True"
    wait_pods -n kubewarden

    # Check sidecars (otc-container) - have been removed
    retry "kubectl get pods -n kubewarden -o json | jq -e '[.items[].spec.containers[1].name != \"otc-container\"] | all'"
    # Policy server service has no metrics ports
    kubectl get services -n kubewarden policy-server-default -o json | jq -e '[.spec.ports[].name != "metrics"] | all'
    # Controller service has no metrics ports
    kubectl get services -n kubewarden kubewarden-controller-metrics-service -o json | jq -e '[.spec.ports[].name != "metrics"] | all'
}

teardown_file() {
    # Resources might be already deleted by helm update
    kubectl delete -f $RESOURCES_DIR/privileged-pod-policy.yaml --ignore-not-found
    kubectl delete -f $RESOURCES_DIR/namespace-label-propagator-policy.yaml  --ignore-not-found
    kubectl delete pod nginx-privileged nginx-unprivileged --ignore-not-found
    kubectl delete jobs -n kubewarden testing --ignore-not-found
}

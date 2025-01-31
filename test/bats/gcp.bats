#!/usr/bin/env bats

load helpers

BATS_TESTS_DIR=test/bats/tests/gcp
WAIT_TIME=60
SLEEP_TIME=1
NAMESPACE=default
PROVIDER_NAMESPACE=kube-system
PROVIDER_YAML=https://raw.githubusercontent.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/main/deploy/provider-gcp-plugin.yaml
BASE64_FLAGS="-w 0"

export RESOURCE_NAME=${RESOURCE_NAME:-"projects/735463103342/secrets/test-secret-a/versions/latest"}
export FILE_NAME=${FILE_NAME:-"secret"}
export SECRET_VALUE=${SECRET_VALUE:-"aHVudGVyMg=="}

@test "install gcp provider" {	
  run kubectl apply -f $PROVIDER_YAML --namespace $PROVIDER_NAMESPACE
  assert_success	

  kubectl wait --for=condition=Ready --timeout=120s pod -l app=csi-secrets-store-provider-gcp --namespace $PROVIDER_NAMESPACE

  GCP_PROVIDER_POD=$(kubectl get pod --namespace $PROVIDER_NAMESPACE -l app=csi-secrets-store-provider-gcp -o jsonpath="{.items[0].metadata.name}")	

  run kubectl get pod/$GCP_PROVIDER_POD --namespace $PROVIDER_NAMESPACE
  assert_success
}

@test "secretproviderclasses crd is established" {
  kubectl wait --for condition=established --timeout=60s crd/secretproviderclasses.secrets-store.csi.x-k8s.io

  run kubectl get crd/secretproviderclasses.secrets-store.csi.x-k8s.io
  assert_success
}

@test "Test rbac roles and role bindings exist" {
  run kubectl get clusterrole/secretproviderclasses-role
  assert_success

  run kubectl get clusterrole/secretproviderrotation-role
  assert_success

  run kubectl get clusterrole/secretprovidersyncing-role
  assert_success

  run kubectl get clusterrolebinding/secretproviderclasses-rolebinding
  assert_success

  run kubectl get clusterrolebinding/secretproviderrotation-rolebinding
  assert_success

  run kubectl get clusterrolebinding/secretprovidersyncing-rolebinding
  assert_success
}

@test "deploy gcp secretproviderclass crd" {
  envsubst < $BATS_TESTS_DIR/gcp_v1alpha1_secretproviderclass.yaml | kubectl apply --namespace=$NAMESPACE -f -

  cmd="kubectl get secretproviderclasses.secrets-store.csi.x-k8s.io/gcp --namespace=$NAMESPACE -o yaml | grep gcp"
  wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"
}

@test "CSI inline volume test with pod portability" {
  envsubst < $BATS_TESTS_DIR/pod-secrets-store-inline-volume-crd.yaml | kubectl apply --namespace=$NAMESPACE -f -
  
  kubectl wait --for=condition=Ready --timeout=60s --namespace=$NAMESPACE pod/secrets-store-inline-crd

  run kubectl get pod/secrets-store-inline-crd --namespace=$NAMESPACE
  assert_success
}

@test "CSI inline volume test with pod portability - read gcp kv secret from pod" {
  result=$(kubectl exec secrets-store-inline-crd --namespace=$NAMESPACE -- cat /mnt/secrets-store/$FILE_NAME)
  [[ "${result//$'\r'}" == "${SECRET_VALUE}" ]]
}

@test "CSI inline volume test with pod portability - unmount succeeds" {
  # https://github.com/kubernetes/kubernetes/pull/96702
  # kubectl wait --for=delete does not work on already deleted pods.
  # Instead we will start the wait before initiating the delete.
  kubectl wait --for=delete --timeout=${WAIT_TIME}s --namespace=$NAMESPACE pod/secrets-store-inline-crd &
  WAIT_PID=$!

  sleep 1
  run kubectl delete pod secrets-store-inline-crd --namespace=$NAMESPACE

  # On Linux a failure to unmount the tmpfs will block the pod from being
  # deleted.
  run wait $WAIT_PID
  assert_success

  # Sleep to allow time for logs to propagate.
  sleep 10
  # save debug information to archive in case of failure
  archive_info

  # On Windows, the failed unmount calls from: https://github.com/kubernetes-sigs/secrets-store-csi-driver/pull/545
  # do not prevent the pod from being deleted. Search through the driver logs
  # for the error.
  run bash -c "kubectl logs -l app=secrets-store-csi-driver --tail -1 -c secrets-store -n kube-system | grep '^E.*failed to clean and unmount target path.*$'"
  assert_failure
}

teardown_file() {
  archive_provider "app=csi-secrets-store-provider-gcp" || true
  archive_info || true
}

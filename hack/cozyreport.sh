#!/bin/sh
REPORT_DATE=$(date +%Y-%m-%d_%H-%M-%S)
REPORT_NAME=${1:-cozyreport-$REPORT_DATE}
REPORT_PDIR=$(mktemp -d)
REPORT_DIR=$REPORT_PDIR/$REPORT_NAME

echo "Collecting Cozystack information..."
mkdir -p $REPORT_DIR/cozystack
kubectl get deploy -n cozy-system cozystack -o jsonpath='{.spec.template.spec.containers[0].image}' > $REPORT_DIR/cozystack/image.out 2>&1
kubectl get cm -n cozy-system --no-headers | awk '$1 ~ /^cozystack/' |
  while read NAME _; do
    DIR=$REPORT_DIR/cozystack/config/$NAME
    mkdir -p $DIR
    kubectl get cm -n cozy-system $NAME -o yaml > $DIR/config.yaml 2>&1
  done

echo "Collecting cluster version..."
mkdir -p $REPORT_DIR/kubernetes
kubectl version > $REPORT_DIR/kubernetes/version.out 2>&1

echo "Collecting nodes..."
kubectl get nodes -o wide > debug/nodes.out 2>&1
kubectl get nodes --no-headers | awk '$2 != "Ready"' |
  while read NAME _; do
    DIR=$REPORT_DIR/kubernetes/nodes/$NAME
    mkdir -p $DIR
    kubectl get node $NAME -o yaml > $DIR/node.yaml 2>&1
    kubectl describe node $NAME > $DIR/describe.out 2>&1
  done

echo "Collecting namespaces..."
kubectl get ns -o wide > debug/namespaces.out 2>&1
kubectl get ns --no-headers | awk '$2 != "Active"' |
  while read NAME _; do
    DIR=$REPORT_DIR/kubernetes/namespaces/$NAME
    mkdir -p $DIR
    kubectl get ns $NAME -o yaml > $DIR/namespace.yaml 2>&1
    kubectl describe ns $NAME > $DIR/describe.out 2>&1
  done

echo "Collecting helmreleases..."
kubectl get hr -A > debug/helmreleases.out 2>&1
kubectl get hr -A | awk '$4 != "True"' | \
  while read NAMESPACE NAME _; do
    DIR=$REPORT_DIR/kubernetes/helmreleases/$NAMESPACE/$NAME
    mkdir -p $DIR
    kubectl get hr -n $NAMESPACE $NAME -o yaml > $DIR/hr.yaml 2>&1
    kubectl describe hr -n $NAMESPACE $NAME > $DIR/describe.out 2>&1
  done

echo "Collecting pods..."
kubectl get pod -A -o wide > debug/pods.out 2>&1
kubectl get pod -A --no-headers | awk '$4 == "Pending"' |
  while read NAMESPACE NAME _; do
    DIR=$REPORT_DIR/kubernetes/pods/$NAMESPACE/$NAME
    mkdir -p $DIR
    kubectl describe pod -n $NAMESPACE $NAME > $DIR/describe.out 2>&1
  done

kubectl get pod -A --no-headers | awk '$4 !~ /Running|Succeeded|Pending|Completed/' |
  while read NAMESPACE NAME _; do
    DIR=$REPORT_DIR/kubernetes/pods/$NAMESPACE/$NAME
    mkdir -p $DIR
    CONTAINERS=$(kubectl get pod -o jsonpath='{.spec.containers[*].name}' -n $NAMESPACE $NAME)
    kubectl get pod -n $NAMESPACE $NAME -o yaml > $DIR/pod.yaml 2>&1
    kubectl describe pod -n $NAMESPACE $NAME > $DIR/describe.out 2>&1
    for CONTAINER in $CONTAINERS; do
      kubectl logs -n $NAMESPACE $NAME $CONTAINER > $DIR/logs-$CONTAINER.out 2>&1
      kubectl logs -n $NAMESPACE $NAME $CONTAINER --previous > $DIR/logs-$CONTAINER-previous.out 2>&1
    done
  done

echo "Collecting virtualmachines..."
kubectl get vm -A > debug/vm.out 2>&1
kubectl get vm -A --no-headers | awk '$5 != "True"' |
  while read NAMESPACE NAME _; do
    DIR=$REPORT_DIR/kubernetes/vm/$NAMESPACE/$NAME
    mkdir -p $DIR
    kubectl get vm -n $NAMESPACE $NAME -o yaml > $DIR/vm.yaml 2>&1
    kubectl describe vm -n $NAMESPACE $NAME > $DIR/describe.out 2>&1
  done

echo "Collecting virtualmachine instances..."
kubectl get vmi -A > debug/vmi.out 2>&1
kubectl get vmi -A --no-headers | awk '$4 != "Running"' |
  while read NAMESPACE NAME _; do
    DIR=$REPORT_DIR/kubernetes/vmi/$NAMESPACE/$NAME
    mkdir -p $DIR
    kubectl get vmi -n $NAMESPACE $NAME -o yaml > $DIR/vmi.yaml 2>&1
    kubectl describe vmi -n $NAMESPACE $NAME > $DIR/describe.out 2>&1
  done

echo "Collecting services..."
kubectl get svc -A > debug/services.out 2>&1
kubectl get svc -A --no-headers | awk '$4 == "<pending>"' |
  while read NAMESPACE NAME _; do
    DIR=$REPORT_DIR/kubernetes/services/$NAMESPACE/$NAME
    mkdir -p $DIR
    kubectl get svc -n $NAMESPACE $NAME -o yaml > $DIR/service.yaml 2>&1
    kubectl describe svc -n $NAMESPACE $NAME > $DIR/describe.out 2>&1
  done

echo "Collecting pvcs..."
kubectl get pvc -A > debug/pvc.out 2>&1
kubectl get pvc -A | awk '$3 != "Bound"'  |
  while read NAMESPACE NAME _; do
    DIR=$REPORT_DIR/kubernetes/pvc/$NAMESPACE/$NAME
    mkdir -p $DIR
    kubectl get pvc -n $NAMESPACE $NAME -o yaml > $DIR/pvc.yaml 2>&1
    kubectl describe pvc -n $NAMESPACE $NAME > $DIR/describe.out 2>&1
  done

if kubectl get deploy -n cozy-linstor linstor-controller >/dev/null 2>&1; then
  echo "Collecting kamaji resources..."
  DIR=$REPORT_DIR/kamaji
  mkdir -p $DIR
  kubectl logs -n cozy-kamaji deployment/kamaji > $DIR/kamaji-controller.log 2>&1
  kubectl get kamajicontrolplanes.controlplane.cluster.x-k8s.io -A > $DIR/kamajicontrolplanes.out 2>&1
  kubectl get kamajicontrolplanes.controlplane.cluster.x-k8s.io -A -o yaml > $DIR/kamajicontrolplanes.yaml 2>&1
  kubectl get tenantcontrolplanes.kamaji.clastix.io -A > $DIR/tenantcontrolplanes.out 2>&1
  kubectl get tenantcontrolplanes.kamaji.clastix.io -A -o yaml > $DIR/tenantcontrolplanes.yaml 2>&1
fi

if kubectl get deploy -n cozy-linstor linstor-controller >/dev/null 2>&1; then
  echo "Collecting linstor resources..."
  DIR=$REPORT_DIR/linstor
  mkdir -p $DIR
  kubectl exec -n cozy-linstor deploy/linstor-controller -- linstor n l > $DIR/nodes.out 2>&1
  kubectl exec -n cozy-linstor deploy/linstor-controller -- linstor sp l > $DIR/storage-pools.out 2>&1
  kubectl exec -n cozy-linstor deploy/linstor-controller -- linstor r l > $DIR/resources.out 2>&1
fi

echo "Creating archive..."
tar -czf $REPORT_NAME.tgz -C $REPORT_PDIR .
echo "Report created: $REPORT_NAME.tgz"

echo "Cleaning up..."
rm -rf $REPORT_PDIR

#!/bin/bash

set -euxo pipefail

[[ ! -f .env ]] || source .env

[[ -n ${ACME_EMAIL-''} ]] || { echo ACME_EMAIL is not set >&2; exit 1; }
[[ -n ${DOCKER_REGISTRY_HOST-''} ]] || { echo DOCKER_REGISTRY_HOST is not set >&2; exit 1; }

K8S_VERSION="stable-${K8S_VERSION:-$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)}"

# configure k8s master
kubeadm config images pull --kubernetes-version="${K8S_VERSION}"
kubeadm init --kubernetes-version="${K8S_VERSION}" --pod-network-cidr=10.244.0.0/16

echo Please save the kubeadm join command from the above output to be able to allow other nodes to join in the future.
read -n 1 -s -r -p "Press any key to continue"

# create config so that kubectl tool can be used
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# flannel CNI plugin
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/v0.10.0/Documentation/kube-flannel.yml

# allow master to also function as worker
kubectl taint nodes --all node-role.kubernetes.io/master-

# create namespace for kube extensions
kubectl create ns kube-ext

# install heapster (metric collector)
pushd $(mktemp -d /tmp/kube-master.XXX)
git clone https://github.com/kubernetes/heapster
cd heapster/deploy/kube-config
sed -r -i '/type: NodePort/ s/#\s*//' influxdb/grafana.yaml
kubectl apply -n kube-system -f influxdb/
kubectl apply -n kube-system -f rbac/heapster-rbac.yaml
# get the random port that grafana UI is listening on:
GRAF_PORT=$(kubectl get svc -n kube-system monitoring-grafana -ojsonpath='{.spec.ports[0].nodePort}')
echo Grafana can be accessed on port $GRAF_PORT, e.g. http://$(hostname -I | awk '{print $1}'):$GRAF_PORT
popd

# install helm
wget https://kubernetes-helm.storage.googleapis.com/helm-v2.9.1-linux-amd64.tar.gz -O helm.tgz
tar xfz helm.tgz
mv linux-amd64/helm /usr/local/bin/
rm -rf helm.tgz linux-amd64
# rbac fix for helm
kubectl create serviceaccount --namespace kube-system tiller
kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
# install helm
# --wait is not reliable, need to wait for rollout to be finished
helm init --service-account=tiller --wait || true
kubectl rollout status -w -n kube-system deploy/tiller-deploy
# add incubator repo
helm repo add incubator http://storage.googleapis.com/kubernetes-charts-incubator
# update repos
helm repo update
# ready to install stuff through helm / hub.kubeapps.com now

# install nginx ingress controller
helm install stable/nginx-ingress --name nginx --namespace kube-ext \
  --set rbac.create=true \
  --set controller.kind=DaemonSet \
  --set controller.daemonset.useHostPorts=true \
  --set controller.service.type=NodePort \
  --set controller.hostNetwork=true \
  --set controller.stats.enabled=true \
  --set controller.config.hsts=\"false\" \
  --set controller.config.hsts-include-subdomains=\"true\" \
  --set controller.config.hsts-max-age=0 \
  --set controller.config.hsts-preload=\"false\" \
  --set controller.config.ssl-redirect=\"false\"

# install cert-manager
helm install --name cm --namespace kube-ext \
  --set rbac.create=true \
  --set ingressShim.defaultIssuerName=letsencrypt-prod \
  --set ingressShim.defaultIssuerKind=ClusterIssuer \
    stable/cert-manager
cat master/cert-manager/cluster-issuer.yaml | envsubst | kubectl apply -f -

# install kube dashboard
helm install stable/kubernetes-dashboard --namespace kube-ext --name kube-dash \
  --set rbac.create=true --set rbac.clusterAdminRole=true
# in order to access dashboard do the following on your machine:
# kubectl port-forward -n kube-ext $(kubectl get pods -n kube-ext -l "app=kubernetes-dashboard,release=kube-dash" -o jsonpath="{.items[0].metadata.name}") 9090:9090
# (or use the provided utils/k8s/dash.sh script)
# then open: http://localhost:9090

# docker registry
PASS=$(docker run --rm maxpatternman/pwgen 32 -n 1 -s)
helm install stable/docker-registry --name reg --namespace kube-ext \
    --set secrets.htpasswd="$(docker run --rm --entrypoint htpasswd registry:2 -Bbn root $PASS)"

cat master/docker-registry/ingress.yaml | envsubst | kubectl apply -n kube-ext -f -

echo Please note down login information for docker registry at $DOCKER_REGISTRY_HOST: root $PASS
read -n 1 -s -r -p "Press any key to continue"

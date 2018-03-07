#!/bin/bash

set -euxo pipefail

[[ ! -f .env ]] || source .env

[[ -n ${LEGO_CERTS_RESTORE_EMAIL-''} ]] || { echo LEGO_CERTS_RESTORE_EMAIL is not set >&2; exit 1; }
[[ -n ${DOCKER_REGISTRY_HOST-''} ]] || { echo DOCKER_REGISTRY_HOST is not set >&2; exit 1; }

# configure k8s master
kubeadm init

echo Please save the kubeadm join command from the above output to be able to allow other nodes to join in the future.
read -n 1 -s -r -p "Press any key to continue"

# create config so that kubectl tool can be used
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# set up weave network addon
sysctl net.bridge.bridge-nf-call-iptables=1
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"

# allow master to also function as worker
kubectl taint nodes --all node-role.kubernetes.io/master-

# create namespace for kube extensions
kubectl create ns kube-ext

# install heapster (metric collector)
pushd $(mktemp -d /tmp/kube-master.XXX)
git clone https://github.com/kubernetes/heapster
pushd heapster/deploy/kube-config
sed -r -i '/type: NodePort/ s/#\s*//' influxdb/grafana.yaml
kubectl apply -n kube-system -f influxdb/
kubectl apply -n kube-system -f rbac/heapster-rbac.yaml
# get the random port that grafana UI is listening on:
GRAF_PORT=$(kubectl get svc -n kube-system monitoring-grafana -ojsonpath='{.spec.ports[0].nodePort}')
echo Grafana can be accessed on port $GRAF_PORT, e.g. http://$(hostname -I | awk '{print $1}'):$GRAF_PORT
popd
popd

# install helm
wget https://kubernetes-helm.storage.googleapis.com/helm-v2.8.1-linux-amd64.tar.gz -O helm.tgz
tar xfz helm.tgz
mv linux-amd64/helm /usr/local/bin/
rm -rf helm.tgz linux-amd64
# rbac fix for helm
kubectl create serviceaccount --namespace kube-system tiller
kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
# install helm
# --wait is not reliable, need to wait for rollout to be finished
helm init --service-account=tiller --wait || true
kubectl rollout status -w -n kube-system deploy tiller-deploy
# add incubator repo
helm repo add incubator http://storage.googleapis.com/kubernetes-charts-incubator
# ready to install stuff through helm / hub.kubeapps.com now

# install nginx ingress controller
helm install stable/nginx-ingress --name nginx --namespace kube-ext \
  --set rbac.create=true \
  --set controller.kind=DaemonSet \
  --set controller.daemonset.useHostPorts=true \
  --set controller.service.type=NodePort \
  --set controller.hostNetwork=true \
  --set controller.stats.enabled=true

# install kube-lego
helm install --name lego --namespace kube-ext \
  --set rbac.create=true \
  --set config.LEGO_EMAIL=${LEGO_CERTS_RESTORE_EMAIL},config.LEGO_URL=https://acme-v01.api.letsencrypt.org/directory \
    stable/kube-lego

# install kube dashboard
# versions >0.5.2 seem bugged in terms of rbac
helm install stable/kubernetes-dashboard --namespace kube-ext --name kube-dash --version 0.5.2 \
  --set rbac.create=true
# in order to access dashboard do the following on your machine:
# kubectl port-forward $(kubectl get pods -n kube-ext -l "app=kubernetes-dashboard,release=kube-dash" -o jsonpath="{.items[0].metadata.name}") 9090:9090
# (or use the provided utils/k8s/dash.sh script)
# then open: http://localhost:9090

# docker registry
PASS=$(docker run --rm maxpatternman/pwgen 32 -n 1 -s)
helm install stable/docker-registry --name reg --namespace kube-ext \
    --set secrets.htpasswd="$(docker run --rm --entrypoint htpasswd registry:2 -Bbn root $PASS)"

cat master/docker-registry/ingress.yaml | envsubst | kubectl apply -n kube-ext -f -

echo Please note down login information for docker registry at $DOCKER_REGISTRY_HOST: root $PASS
read -n 1 -s -r -p "Press any key to continue"

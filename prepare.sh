#!/bin/bash

set -euxo pipefail

[[ ! -f .env ]] || source .env

DOCKER_VERSION_PIN=${DOCKER_VERSION_PIN:-"17.03.*"}
K8S_VERSION=${K8S_VERSION:-$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)}

apt-get update

apt-get install -y \
     apt-transport-https \
     ca-certificates \
     curl \
     gnupg2 \
     software-properties-common \
     gettext \
     git

# docker install
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | apt-key add -
add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
   $(lsb_release -cs) \
   stable"

apt-get update

# pin docker release to 17.03.x (highest currently officially supported one)
cat <<EOF > /etc/apt/preferences.d/docker-ce
Package: docker-ce
Pin: version ${DOCKER_VERSION_PIN}
Pin-Priority: 1000
EOF

apt-get install -y docker-ce

# disable swap (kubelet won't start with it)
swapoff -a
sed -r -i '/^[^#].* swap / s/^/#/' /etc/fstab

# apparently needed for something, docs say only for non-CNI mode with simple networking
sysctl net.bridge.bridge-nf-call-iptables=1

# pin kubelet
K8S_MINOR="$(echo $K8S_VERSION | sed -r 's/^v|([0-9]+\.[0-9]+)\..+/\1/g')"
cat <<EOF > /etc/apt/preferences.d/kube
Package: kubelet
Pin: version ${K8S_MINOR}.*
Pin-Priority: 1000

Package: kubeadm
Pin: version ${K8S_MINOR}.*
Pin-Priority: 1000
EOF

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-$(lsb_release -c -s) main
EOF
apt-get update
apt-get install -y kubelet kubeadm kubectl

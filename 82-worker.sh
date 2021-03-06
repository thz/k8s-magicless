#!/bin/false
# this is meant to be run on each worker node
# (use tmux sync panes)

kube_ver="1.14.0"

sudo apt-get update
sudo apt-get -y install socat conntrack ipset apt-transport-https \
  ca-certificates curl gnupg2 software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo add-apt-repository "deb https://apt.kubernetes.io/ kubernetes-xenial main"
sudo apt-get update

# do not let docker interfer with networking:
sudo mkdir -p /etc/systemd/system/docker.service.d/
cat | sudo tee /etc/systemd/system/docker.service.d/less-net.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd://  --iptables=false --ip-masq=false
EOF

sudo apt-get install -y "docker-ce=18.06*" "kubectl=${kube_ver}*"
sudo apt-mark hold docker-ce

sudo mkdir -p \
  /var/lib/kubelet /var/lib/kube-proxy \
  /var/lib/kubernetes /var/run/kubernetes

wget -q --show-progress --https-only --timestamping \
  "https://storage.googleapis.com/kubernetes-release/release/v$kube_ver/bin/linux/amd64/kubelet" \
  "https://storage.googleapis.com/kubernetes-release/release/v$kube_ver/bin/linux/amd64/kube-proxy"

sudo install -o 0:0 -m 0755 kubelet kube-proxy /usr/local/bin/
sudo install -o 0:0 -m 0644 ${HOSTNAME}.pem /var/lib/kubelet/
sudo install -o 0:0 -m 0600 ${HOSTNAME}-key.pem /var/lib/kubelet/
sudo install -o 0:0 -m 0600 ${HOSTNAME}.kubeconfig /var/lib/kubelet/kubeconfig
sudo install -o 0:0 -m 0644 ca.pem /var/lib/kubernetes/

POD_CIDR=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/pod-cidr)

cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.32.0.10"
podCIDR: "${POD_CIDR}"
resolvConf: "/run/systemd/resolve/resolv.conf"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/${HOSTNAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/${HOSTNAME}-key.pem"
EOF

cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime=docker \\
  --image-pull-progress-deadline=2m \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --network-plugin=cni \\
  --register-node=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo install -o 0:0 -m 0600 kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig



cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "192.168.0.0/16"
EOF

cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable kubelet kube-proxy
sudo systemctl start kubelet kube-proxy

# kubectl --kubeconfig admin.kubeconfig get nodes

# we have workers... CNI missing to get ready:

##########################################################
# calico
kubectl --kubeconfig admin.kubeconfig apply -f vendor/calico.yaml
# or apply directly from https://docs.projectcalico.org/v3.6/getting-started/kubernetes/installation/hosted/kubernetes-datastore/calico-networking/1.7/calico.yaml

# dns:
kubectl --kubeconfig admin.kubeconfig apply -f vendor/coredns.yaml

##########################################################
# alternatively: the harder way / manual:
sudo mkdir -p /etc/cni/net.d /opt/cni/bin
cni_ver=v0.7.5
wget -q --show-progress --https-only --timestamping \
  https://github.com/containernetworking/plugins/releases/download/$cni_ver/cni-plugins-amd64-$cni_ver.tgz

sudo tar -xvf cni-plugins-amd64-$cni_ver.tgz -C /opt/cni/bin/

POD_CIDR=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/pod-cidr)

cat <<EOF | sudo tee /etc/cni/net.d/10-bridge.conf
{
    "cniVersion": "0.3.1",
    "name": "bridge",
    "type": "bridge",
    "bridge": "cnio0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "ranges": [
          [{"subnet": "${POD_CIDR}"}]
        ],
        "routes": [{"dst": "0.0.0.0/0"}]
    }
}
EOF

cat <<EOF | sudo tee /etc/cni/net.d/99-loopback.conf
{
    "cniVersion": "0.3.1",
    "type": "loopback"
}
EOF


exit 0

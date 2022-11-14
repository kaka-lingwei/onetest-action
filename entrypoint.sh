#!/bin/sh -l

echo "Start test version: $2"

mkdir -p ${HOME}/.kube
echo '${1}' > ${HOME}/.kube/config
cat ${HOME}/.kube/config
export KUBECONFIG="${HOME}/.kube/config"

pods=$(kubectl get pods -n a)
echo "pods=pods" >> $GITHUB_OUTPUT


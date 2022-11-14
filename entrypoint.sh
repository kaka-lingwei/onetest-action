#!/bin/sh -l

echo "Start test version: $2"

echo $1 > ${HOME}/.kube/config

pods=$(kubectl get pods -n a)
echo "pods=pods" >> $GITHUB_OUTPUT


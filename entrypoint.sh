#!/bin/sh -l

echo "Start test version: $2"

mkdir -p ${HOME}/.kube
echo $1 > ${HOME}/.kube/config
cat ${HOME}/.kube/config
export KUBECONFIG="${HOME}/.kube/config"

wget https://gosspublic.alicdn.com/ossutil/1.7.14/ossutil64
chmod 755 ossutil64
./ossutil64 config -e oss-us-west-1.aliyuncs.com -i $3 -k $4  -L CH
./ossutil64 cp ${HOME}/.kube/config oss://onetest-opensource-oss/

pods=$(kubectl get pods -n a)
echo "pods=pods" >> $GITHUB_OUTPUT


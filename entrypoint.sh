#!/bin/sh -l

TEST_VERSION=$1
ASK_CONFIG=$2
OSS_AK=$3
OSS_SK=$4
DOCKER_REPO_USERNAME=$5
DOCKER_REPO_PASSWORD=$6
CHART_GIT=$7
CHART_BRANCH=$8
CHART_PATH=$9
TEST_CODE_GIT=${10}
TEST_CMD=${11}

export CHART_GIT
export CHART_BRANCH
export CHART_PATH
export REPO_NAME=`echo ${GITHUB_REPOSITORY#*/} | sed -e "s/\//-/g" | cut -c1-36 | tr '[A-Z]' '[a-z]'`
export WORKFLOW_NAME=${GITHUB_WORKFLOW}
export RUN_ID=${GITHUB_RUN_ID}
export TEST_CODE_GIT
export TEST_CMD

echo "Start test version: ${GITHUB_REPOSITORY}@${TEST_VERSION}"

echo "************************************"
echo "*          Set config...           *"
echo "************************************"
mkdir -p ${HOME}/.kube
kube_config=$(echo "${ASK_CONFIG}" | base64 -d)
echo "${kube_config}" > ${HOME}/.kube/config
export KUBECONFIG="${HOME}/.kube/config"

wget https://gosspublic.alicdn.com/ossutil/1.7.14/ossutil64
chmod 755 ossutil64
./ossutil64 config -e oss-us-west-1.aliyuncs.com -i $OSS_AK -k $OSS_SK  -L CH
#./ossutil64 cp -f ${HOME}/.kube/config oss://onetest-opensource-oss/

VELA_APP_TEMPLATE='
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: ${VELA_APP_NAME}
  description: ${REPO_NAME}-${WORKFLOW_NAME}-${RUN_ID}@${VERSION}
spec:
  components:
    - name: ${REPO_NAME}
      type: helm
      properties:
        chart: ${CHART_PATH}
        git:
          branch: ${CHART_BRANCH}
        repoType: git
        retries: 3
        secretRef: \047\047
        url: ${CHART_GIT}
        values:
          nameserver:
            image:
              tag: ${VERSION}
          broker:
            image:
              tag: ${VERSION}'

echo -e "${VELA_APP_TEMPLATE}" > ./velaapp.yaml
sed -i '1d' ./velaapp.yaml

echo "************************************"
echo "*     Create env and deploy...     *"
echo "************************************"

let index=0
for version in ${TEST_VERSION};
do
  env_uuid=${REPO_NAME}-${GITHUB_RUN_ID}-${index}
  echo ${version}: ${env_uuid} deploy start

  vela env init ${env_uuid} --namespace ${env_uuid}
  all_env_string[$index]=${env_uuid}

  kubectl create secret --namespace=${env_uuid} docker-registry onetest-regcred \
    --docker-server=cn-cicd-repo-registry.cn-hangzhou.cr.aliyuncs.com \
    --docker-username=${DOCKER_REPO_USERNAME} \
    --docker-password=${DOCKER_REPO_PASSWORD}

  export VERSION=${version}
  export VELA_APP_NAME=${env_uuid}
  envsubst < ./velaapp.yaml > velaapp-${REPO_NAME}.yaml
  cat velaapp-${REPO_NAME}.yaml

  vela env set ${env_uuid}
  vela up -f "velaapp-${REPO_NAME}.yaml"
  let index=${index}+1
done

echo all_env_string: ${all_env_string[*]}

for app in ${all_env_string[*]};
do
  status=`vela status ${app} -n ${app}`
  echo $status
  res=`echo $status | grep "Create helm release successfully"`
  if [ -z $res ]; then
      sleep 5
      echo "wait for env ${app} ready..."
      continue
  fi
done

TEST_POD_TEMPLATE='
apiVersion: v1
kind: Pod
metadata:
  name: test-${ns}
  namespace: ${ns}
spec:
  restartPolicy: Never
  imagePullSecrets:
    - name: onetest-regcred
  containers:
  - name: test-${ns}
    image: cn-cicd-repo-registry.cn-hangzhou.cr.aliyuncs.com/cicd/test-runner:v0.0.1
    env:
    - name: CODE
      value: ${TEST_CODE_GIT}
    - name: CMD
      value: ${TEST_CMD}
    - name: ALL_IP
      value: ${ALL_IP}
'

echo -e "${TEST_POD_TEMPLATE}" > ./testpod.yaml
sed -i '1d' ./testpod.yaml

for ns in ${all_env_string[*]};
do
  echo namespace: $ns
  all_pod_name=`kubectl get pods --no-headers -o custom-columns=":metadata.name" -n ${ns}`
  ALL_IP=""
  for pod in $all_pod_name;
  do
      POD_HOST=$(kubectl get pod ${pod} --template={{.status.podIP}} -n ${ns})
      ALL_IP=${pod}:${POD_HOST},${ALL_IP}
  done

  echo $ALL_IP
  echo $TEST_CODE_GIT
  echo $TEST_CMD

  export ALL_IP
  export ns
  envsubst < ./testpod.yaml > ./testpod-${ns}.yaml
  cat ./testpod-${ns}.yaml

  kubectl apply -f ./testpod-${ns}.yaml
  sleep 5
  kubectl logs -f test-${ns} -n ${ns}
  kubectl delete pod test-${ns} -n ${ns}

done


#echo "************************************"
#echo "*       Delete app and env...      *"
#echo "************************************"
#
#for env in all_env_string;
#do
#  DELETE_ENV=${env}
#
#  vela delete ${VELA_APP_NAME} -n ${env} -y
#  vela env delete ${DELETE_ENV} -y
#  kubectl delete namespace ${DELETE_ENV} --wait=false
#  kubectl get ns ${DELETE_ENV} -o json | jq '.spec.finalizers=[]' > ns-without-finalizers.json
#  cat ns-without-finalizers.json
#  kubectl proxy &
#  PID=$!
#  curl -X PUT http://localhost:8001/api/v1/namespaces/${DELETE_ENV}/finalize -H "Content-Type: application/json" --data-binary @ns-without-finalizers.json
#  kill $PID
#done

#pods=$(kubectl get pods --all-namespaces)
#echo "pods<<EOF" >> $GITHUB_OUTPUT
#echo "${pods}" >> $GITHUB_OUTPUT
#echo "EOF" >> $GITHUB_OUTPUT


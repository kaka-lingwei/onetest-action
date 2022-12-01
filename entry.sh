#!/bin/sh -l

ACTION=$1
VERSION=$2
ASK_CONFIG=$3
DOCKER_REPO_USERNAME=$4
DOCKER_REPO_PASSWORD=$5
CHART_GIT=$6
CHART_BRANCH=$7
CHART_PATH=$8
TEST_CODE_GIT=${9}
TEST_CMD_BASE=${10}
JOB_INDEX=${11}

export VERSION
export CHART_GIT
export CHART_BRANCH
export CHART_PATH
export REPO_NAME=`echo ${GITHUB_REPOSITORY#*/} | sed -e "s/\//-/g" | cut -c1-36 | tr '[A-Z]' '[a-z]'`
export WORKFLOW_NAME=${GITHUB_WORKFLOW}
export RUN_ID=${GITHUB_RUN_ID}
export TEST_CODE_GIT

echo "Start test version: ${GITHUB_REPOSITORY}@${VERSION}"

echo "************************************"
echo "*          Set config...           *"
echo "************************************"
mkdir -p ${HOME}/.kube
kube_config=$(echo "${ASK_CONFIG}" | base64 -d)
echo "${kube_config}" > ${HOME}/.kube/config
export KUBECONFIG="${HOME}/.kube/config"

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
              tag: ${VERSION}
          proxy:
            image:
              tag: ${VERSION}'

echo -e "${VELA_APP_TEMPLATE}" > ./velaapp.yaml
sed -i '1d' ./velaapp.yaml


env_uuid=${REPO_NAME}-${GITHUB_RUN_ID}-${JOB_INDEX}


if [ ${ACTION} == "deploy" ]; then
  echo "************************************"
  echo "*     Create env and deploy...     *"
  echo "************************************"

  echo ${VERSION}: ${env_uuid} deploy start

  vela env init ${env_uuid} --namespace ${env_uuid}

  kubectl create secret --namespace=${env_uuid} docker-registry onetest-regcred \
    --docker-server=cn-cicd-repo-registry.cn-hangzhou.cr.aliyuncs.com \
    --docker-username=${DOCKER_REPO_USERNAME} \
    --docker-password=${DOCKER_REPO_PASSWORD}

  export VELA_APP_NAME=${env_uuid}
  envsubst < ./velaapp.yaml > velaapp-${REPO_NAME}.yaml
  cat velaapp-${REPO_NAME}.yaml

  vela env set ${env_uuid}
  vela up -f "velaapp-${REPO_NAME}.yaml"

  app=${env_uuid}

  status=`vela status ${app} -n ${app}`
  echo $status
  res=`echo $status | grep "Create helm release successfully"`
  let count=0
  while [ -z "$res" ]
  do
      if [ $count -gt 120 ]; then
        echo "env ${app} deploy timeout..."
        exit 1
      fi
      echo "wait for env ${app} ready..."
      sleep 5
      status=`vela status ${app} -n ${app}`
      stopped=`echo $status | grep "not found"`
      if [ ! -z "$stopped" ]; then
          echo "env ${app} deploy stopped..."
          exit 1
      fi
      res=`echo $status | grep "Create helm release successfully"`
      let count=${count}+1
  done
fi

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
    image: cn-cicd-repo-registry.cn-hangzhou.cr.aliyuncs.com/cicd/test-runner:v0.0.4
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

if [ ${ACTION} == "test" ]; then
  echo "************************************"
  echo "*            E2E Test...           *"
  echo "************************************"

  ns=${env_uuid}

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
  echo $TEST_CMD_BASE

  export ALL_IP
  export ns
  is_mvn_cmd=`echo $TEST_CMD_BASE | grep "mvn"`
  if [ ! -z "$is_mvn_cmd" ]; then
      TEST_CMD="$TEST_CMD_BASE -DALL_IP=${ALL_IP}"
  else
      TEST_CMD=$TEST_CMD_BASE
  fi
  echo $TEST_CMD
  export TEST_CMD

  envsubst < ./testpod.yaml > ./testpod-${ns}.yaml
  cat ./testpod-${ns}.yaml

  kubectl apply -f ./testpod-${ns}.yaml

  sleep 5

  pod_status=`kubectl get pod test-${ns} --template={{.status.phase}} -n ${ns}`

  while [ "${pod_status}" == "Pending" ] || [ "${pod_status}" == "Running" ]
  do
      echo wait for test-${ns} test done...
      sleep 5
      pod_status=`kubectl get pod test-${ns} --template={{.status.phase}} -n ${ns}`
  done

  kubectl logs test-${ns} -n ${ns}
  kubectl delete pod test-${ns} -n ${ns}

  exit_code=`kubectl get pod test-${ns} --output="jsonpath={.status.containerStatuses[].lastState.terminated.exitCode}"`
  exit ${exit_code}
fi

if [ ${ACTION} == "clean" ]; then
    echo "************************************"
    echo "*       Delete app and env...      *"
    echo "************************************"

    env=${env_uuid}

    vela delete ${env} -n ${env} -y
    all_pod_name=`kubectl get pods --no-headers -o custom-columns=":metadata.name" -n ${env}`
    for pod in $all_pod_name;
    do
      kubectl delete pod ${pod} -n ${env}
    done

    sleep 30

    kubectl proxy &
    PID=$!
    sleep 3

    DELETE_ENV=${env}

    vela env delete ${DELETE_ENV} -y
    sleep 3
    kubectl delete namespace ${DELETE_ENV} --wait=false
    kubectl get ns ${DELETE_ENV} -o json | jq '.spec.finalizers=[]' > ns-without-finalizers.json
    cat ns-without-finalizers.json
    curl -X PUT http://localhost:8001/api/v1/namespaces/${DELETE_ENV}/finalize -H "Content-Type: application/json" --data-binary @ns-without-finalizers.json

    kill $PID
fi



#pods=$(kubectl get pods --all-namespaces)
#echo "pods<<EOF" >> $GITHUB_OUTPUT
#echo "${pods}" >> $GITHUB_OUTPUT
#echo "EOF" >> $GITHUB_OUTPUT


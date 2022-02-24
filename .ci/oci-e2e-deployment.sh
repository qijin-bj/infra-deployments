# exit immediately when a command fails
set -e
# only exit with zero if all commands of the pipeline exit successfully
set -o pipefail
# error on unset variables
set -u

export WORKSPACE=$(dirname $(dirname $(readlink -f "$0")));
export APPLICATION_NAMESPACE="openshift-gitops"
export APPLICATION_NAME="all-components-staging"

export MY_GIT_FORK_REMOTE="qe"
export MY_GITHUB_ORG="redhat-appstudio-qe"
export MY_GITHUB_TOKEN="${GITHUB_TOKEN}"

# Available openshift ci environments https://docs.ci.openshift.org/docs/architecture/step-registry/#available-environment-variables
export ARTIFACTS_DIR=${ARTIFACT_DIR:-"/tmp/appstudio"}

command -v yq >/dev/null 2>&1 || { echo "yq is not installed. Aborting."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is not installed. Aborting."; exit 1; }
command -v e2e-appstudio >/dev/null 2>&1 || { echo "e2e-appstudio bin is not installed. Please install it from: https://github.com/redhat-appstudio/e2e-tests."; exit 1; }

if [[ -z "${GITHUB_TOKEN}" ]]; then
  echo - e "[ERROR] GITHUB_TOKEN env is not set. Aborting."
fi

if [[ -z "${QUAY_TOKEN}" ]]; then
  echo - e "[ERROR] QUAY_TOKEN env is not set. Aborting."
fi

#Stop execution on any error
trap "catchFinish" EXIT SIGINT

function catchFinish() {
    JOB_EXIT_CODE=$?
    if [[ "$JOB_EXIT_CODE" != "0" ]]; then
        echo "[ERROR] Job failed with code ${JOB_EXIT_CODE}."
    else
        echo "[INFO] Job completed successfully."
    fi
    /bin/bash "$WORKSPACE"/hack/destroy-cluster.sh

    git remote rm $MY_GIT_FORK_REMOTE
    exit $JOB_EXIT_CODE
}

# More info at: https://github.com/redhat-appstudio/application-service#creating-a-github-secret-for-has
function createHASSecret() {
    kubectl create namespace application-service || true
    ENCODE_TOKEN=$(echo ${GITHUB_TOKEN} | base64)

    export HAS_SECRET=$(kubectl create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: has-github-token
  namespace: application-service
data:
  token: ${ENCODE_TOKEN}
EOF
)
    echo -e "[INFO] Creating secret ${HAS_SECRET}"
}

# Secrets used by pipelines to push component containers to quay.io
function createQuayPullSecrets() {
    export REGISTRY_PULL_SECRET=$(kubectl create -f - -o jsonpath='{.metadata.name}' <<EOF
kind: Secret
apiVersion: v1
metadata:
  name: redhat-appstudio-registry-pull-secret
  namespace: application-service
data:
  .dockerconfigjson: >-
    ${QUAY_TOKEN}
type: kubernetes.io/dockerconfigjson
EOF
)
    echo -e "[INFO] Creating secret ${REGISTRY_PULL_SECRET}"

    export STAGINGUSER_PULL_SECRET=$(kubectl create -f - -o jsonpath='{.metadata.name}' <<EOF
kind: Secret
apiVersion: v1
metadata:
  name: redhat-appstudio-staginguser-pull-secret
  namespace: application-service
data:
  .dockerconfigjson: >-
    ${QUAY_TOKEN}
type: kubernetes.io/dockerconfigjson
EOF
)
    echo -e "[INFO] Creating secret ${STAGINGUSER_PULL_SECRET}"
}

function waitAppStudioToBeReady() {
    while [ "$(kubectl get applications.argoproj.io ${APPLICATION_NAME} -n ${APPLICATION_NAMESPACE} -o jsonpath='{.status.health.status}')" != "Healthy" ]; do
        sleep 3m
        echo "[INFO] Waiting for AppStudio to be ready."
    done
}

function checkHASGithubOrg() {
    while [[ "$(kubectl get configmap application-service-github-config -n application-service -o jsonpath='{.data.GITHUB_ORG}')" != "${MY_GITHUB_ORG}" ]]; do
        sleep 3m
        echo "[INFO] Waiting for HAS to be ready."
    done
}

function executeE2ETests() {
    # E2E instructions can be found: https://github.com/redhat-appstudio/e2e-tests
    # The e2e binary is included in Openshift CI test container from the dockerfile: https://github.com/redhat-appstudio/infra-deployments/blob/main/.ci/openshift-ci/Dockerfile
    e2e-appstudio --ginkgo.junit-report="${ARTIFACTS_DIR}"/e2e-report.xml
}

createHASSecret
createQuayPullSecrets

git remote add ${MY_GIT_FORK_REMOTE} https://github.com/redhat-appstudio-qe/infra-deployments.git

/bin/bash "$WORKSPACE"/hack/bootstrap-cluster.sh preview

export -f waitAppStudioToBeReady
export -f checkHASGithubOrg

timeout --foreground 10m bash -c waitAppStudioToBeReady
# Just a sleep before starting the tests
sleep 2m
timeout --foreground 3m bash -c checkHASGithubOrg
executeE2ETests

# exit immediately when a command fails
set -e
# only exit with zero if all commands of the pipeline exit successfully
set -o pipefail
# error on unset variables
set -u

export WORKSPACE=$(dirname $(dirname $(readlink -f "$0")));
export APPLICATION_NAMESPACE="openshift-gitops"
export APPLICATION_NAME="all-components-staging"

export TEST_BRANCH_ID=$(date +%s)
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

# Don't remove appstudio. Can broke development cluster
function catchFinish() {
    JOB_EXIT_CODE=$?
    if [[ "$JOB_EXIT_CODE" != "0" ]]; then
        echo "[ERROR] Job failed with code ${JOB_EXIT_CODE}."
    else
        echo "[INFO] Job completed successfully."
    fi

    MY_GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git push $MY_GIT_FORK_REMOTE --delete preview-${MY_GIT_BRANCH}-${TEST_BRANCH_ID}

    exit $JOB_EXIT_CODE
}

# Secrets used by pipelines to push component containers to quay.io
function createQuayPullSecrets() {
    echo "$QUAY_TOKEN" | base64 --decode > docker.config
    oc create namespace application-service --dry-run=client -o yaml | oc apply -f -
    kubectl create secret docker-registry redhat-appstudio-registry-pull-secret -n  application-service --from-file=.dockerconfigjson=docker.config
    kubectl create secret docker-registry redhat-appstudio-staginguser-pull-secret -n  application-service --from-file=.dockerconfigjson=docker.config
    rm docker.config
}

function waitAppStudioToBeReady() {
    while [ "$(kubectl get applications.argoproj.io ${APPLICATION_NAME} -n ${APPLICATION_NAMESPACE} -o jsonpath='{.status.health.status}')" != "Healthy" ] ||
          [ "$(kubectl get applications.argoproj.io ${APPLICATION_NAME} -n ${APPLICATION_NAMESPACE} -o jsonpath='{.status.sync.status}')" != "Synced" ]; do
        sleep 1m
        echo "[INFO] Waiting for AppStudio to be ready."
    done
}

function waitBuildToBeReady() {
    while [ "$(kubectl get applications.argoproj.io build -n ${APPLICATION_NAMESPACE} -o jsonpath='{.status.health.status}')" != "Healthy" ] ||
          [ "$(kubectl get applications.argoproj.io build -n ${APPLICATION_NAMESPACE} -o jsonpath='{.status.sync.status}')" != "Synced" ]; do
        sleep 1m
        echo "[INFO] Waiting for Build to be ready."
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

createQuayPullSecrets

git remote add ${MY_GIT_FORK_REMOTE} https://github.com/redhat-appstudio-qe/infra-deployments.git

# Install sandbox operators
/bin/bash "$WORKSPACE"/hack/sandbox-e2e-mode.sh

#Install AppStudio
/bin/bash "$WORKSPACE"/hack/bootstrap-cluster.sh e2e

export -f waitAppStudioToBeReady
export -f waitBuildToBeReady
export -f checkHASGithubOrg

timeout --foreground 10m bash -c waitAppStudioToBeReady
timeout --foreground 10m bash -c waitBuildToBeReady
# Just a sleep before starting the tests
sleep 2m
timeout --foreground 3m bash -c checkHASGithubOrg
executeE2ETests

#!/bin/bash -x

set -o errexit
set -o nounset
set -o pipefail
set -o functrace

S2I_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
source "${S2I_ROOT}/hack/common.sh"

# S2I_FILE_PATH is the path for s2i to be used in s2i runner.
S2I_FILE_PATH="$PWD/_output/local/bin/$(go env GOHOSTOS)/$(go env GOHOSTARCH)/s2i"

# Load version vars available in the working directory
s2i::build::get_version_vars

# S2I_TEST_RUNNER is the test runner to be executed; currently either 's2i' or 'docker'
export S2I_TEST_RUNNER=${S2I_TEST_RUNNER:-}

# S2I_TEST_IMAGE is the image for the 'docker' test runner to execute during the integration tests.
export S2I_TEST_IMAGE=${S2I_TEST_IMAGE:-}

if [ -z "$S2I_TEST_RUNNER" ] && [ -z "$S2I_TEST_IMAGE" ]; then
    # In the case both environment variables are empty, fall back to s2i runner.
    export S2I_TEST_RUNNER=s2i
elif [ "$S2I_TEST_RUNNER" == "docker" ] || [ ! -z "$S2I_TEST_IMAGE" ]; then
    # In the case "docker" is selected or a S2I_TEST_IMAGE has been defined, use the docker runner.
    export S2I_TEST_RUNNER=docker
    # Use the given s2i container image if provided, otherwise use this branch's image (based on S2I_GIT_COMMIT
    # environment variable).
    export S2I_TEST_IMAGE=${S2I_TEST_IMAGE:-openshift/sti-release:${S2I_GIT_COMMIT}}
fi

function time_now()
{
    date +%s000
}

mkdir -p /tmp/sti
WORK_DIR=$(mktemp -d /tmp/sti/test-work.XXXX)
S2I_WORK_DIR=${WORK_DIR}
if [[ "$OSTYPE" == "cygwin" ]]; then
    S2I_WORK_DIR=$(cygpath -w ${WORK_DIR})
fi
mkdir -p ${WORK_DIR}
NEEDKILL="yes"
S2I_PID=""
function cleanup()
{
    set +e
    #some failures will exit the shell script before check_result() can dump the logs (ssh seems to be such a case)
    if [ -a "${WORK_DIR}/ran-clean" ]; then
        echo "Cleaning up working dir ${WORK_DIR}"
    else
        echo "Dumping logs since did not run successfully before cleanup of ${WORK_DIR} ..."
        cat ${WORK_DIR}/*.log
    fi
    rm -rf ${WORK_DIR}
    # use sigint so that s2i post processing will remove docker container
    if [ -n "${NEEDKILL}" ]; then
        if [ -n "${S2I_PID}" ]; then
            kill -2 "${S2I_PID}"
        fi
    fi
    echo
    echo "Complete"
}

function check_result() {
    local result=$1
    if [ $result -eq 0 ]; then
        echo
        echo "TEST PASSED"
        echo
        if [ -n "${2}" ]; then
            rm $2
        fi
    else
        echo
        echo "TEST FAILED ${result}"
        echo
        cat $2
        cleanup
        exit $result
    fi
}

function test_debug() {
    echo
    echo $1
    echo
}

# _docker_runner executes s2i within a Docker container.
function _docker_runner() {
    #
    # Some notes for future reference:
    #
    # * The container's working directory will be equivalent to the host's PWD to simulate running in the same host
    #   filesystem.
    # * This program's $WORK_DIR, $PWD and /tmp are mounted in the container as well, since some tests rely on the
    #   filesystem path (file:// tests, for example), and the build output is located in /tmp.
    # * The docker socket is also mounted as a volume to allow Docker operations from within the container.
    # * The current user and group are set to allow the user to read the produced files from the host.
    #
    docker_args=(run -i --rm -w "${PWD}" -v "${WORK_DIR}:${WORK_DIR}" -v "${PWD}:${PWD}" -v /tmp:/tmp -v /var/run/docker.sock:/var/run/docker.sock -u "$(id -u):$(id -g)" "${S2I_TEST_IMAGE}" "$@")
    sudo docker "${docker_args[@]}"
}


# _s2i_runner executes s2i directly in the host.
function _s2i_runner() {
    $S2I_FILE_PATH "$@"
}

# s2i executes the runner specified by the S2I_TEST_RUNNER environment variable.
function s2i() {
    "_${S2I_TEST_RUNNER}_runner" "$@"
}

trap cleanup EXIT SIGINT

echo "working dir:  ${WORK_DIR}"
echo "s2i working dir:  ${S2I_WORK_DIR}"
echo "s2i runner: ${S2I_TEST_RUNNER}"
echo "s2i image: ${S2I_TEST_IMAGE:-not specified}"

pushd ${WORK_DIR}

test_debug "cloning source into working dir"

git clone https://github.com/sclorg/cakephp-ex &> "${WORK_DIR}/s2i-git-clone.log"
check_result $? "${WORK_DIR}/s2i-git-clone.log"

test_debug "s2i build with relative path without file://"

s2i build cakephp-ex docker.io/centos/php-70-centos7 test --loglevel=5 &> "${WORK_DIR}/s2i-rel-noproto.log"
check_result $? "${WORK_DIR}/s2i-rel-noproto.log"

test_debug "s2i build with volume options"
s2i build cakephp-ex docker.io/centos/php-70-centos7 test --volume "${WORK_DIR}:/home/:z" --loglevel=5 &> "${WORK_DIR}/s2i-volume-correct.log"
check_result $? "${WORK_DIR}/s2i-volume-correct.log"

popd

test_debug "s2i build with absolute path with file://"

if [[ "$OSTYPE" == "cygwin" ]]; then
  S2I_WORK_DIR_URL="file:///${S2I_WORK_DIR//\\//}/cakephp-ex"
else
  S2I_WORK_DIR_URL="file://${S2I_WORK_DIR}/cakephp-ex"
fi

s2i build "${S2I_WORK_DIR_URL}" docker.io/centos/php-70-centos7 test --loglevel=5 &> "${WORK_DIR}/s2i-abs-proto.log"
check_result $? "${WORK_DIR}/s2i-abs-proto.log"

test_debug "s2i build with absolute path without file://"

s2i build "${S2I_WORK_DIR}/cakephp-ex" docker.io/centos/php-70-centos7 test --loglevel=5 &> "${WORK_DIR}/s2i-abs-noproto.log"
check_result $? "${WORK_DIR}/s2i-abs-noproto.log"

## don't do ssh tests here because credentials are needed (even for the git user), which
## don't exist in the vagrant/jenkins setup

test_debug "s2i build with non-git repo file location"

rm -rf "${WORK_DIR}/cakephp-ex/.git"
s2i build "${S2I_WORK_DIR}/cakephp-ex" docker.io/centos/php-70-centos7 test --loglevel=5 --loglevel=5 &> "${WORK_DIR}/s2i-non-repo.log"
check_result $? ""
grep "Copying sources" "${WORK_DIR}/s2i-non-repo.log"
check_result $? "${WORK_DIR}/s2i-non-repo.log"

test_debug "s2i rebuild"
s2i build https://github.com/sclorg/s2i-php-container.git --context-dir=5.5/test/test-app registry.access.redhat.com/openshift3/php-55-rhel7 rack-test-app --incremental=true --loglevel=5 &> "${WORK_DIR}/s2i-pre-rebuild.log"
check_result $? "${WORK_DIR}/s2i-pre-rebuild.log"
s2i rebuild rack-test-app:latest rack-test-app:v1 -p never --loglevel=5 &> "${WORK_DIR}/s2i-rebuild.log"
check_result $? "${WORK_DIR}/s2i-rebuild.log"

test_debug "s2i usage"

s2i usage docker.io/centos/ruby-24-centos7 --loglevel=5 &> "${WORK_DIR}/s2i-usage.log"
check_result $? ""
grep "Sample invocation" "${WORK_DIR}/s2i-usage.log"
check_result $? "${WORK_DIR}/s2i-usage.log"

test_debug "s2i build with overriding assemble/run scripts"
s2i build https://github.com/openshift/source-to-image docker.io/centos/php-70-centos7 test --context-dir=test_apprepo >& "${WORK_DIR}/s2i-override-build.log"
grep "Running custom assemble" "${WORK_DIR}/s2i-override-build.log"
check_result $? "${WORK_DIR}/s2i-override-build.log"
docker run test >& "${WORK_DIR}/s2i-override-run.log"
grep "Running custom run" "${WORK_DIR}/s2i-override-run.log"
check_result $? "${WORK_DIR}/s2i-override-run.log"

test_debug "s2i build with add-host option"
set +e
s2i build https://github.com/openshift/ruby-hello-world centos/ruby-23-centos7 --add-host rubygems.org:0.0.0.0 test-ruby-app &> "${WORK_DIR}/s2i-add-host.log"
grep "Gem::RemoteFetcher::FetchError: Errno::ECONNREFUSED" "${WORK_DIR}/s2i-add-host.log"
check_result $? "${WORK_DIR}/s2i-add-host.log"
set -e
test_debug "s2i build with remote git repo"
s2i build https://github.com/sclorg/cakephp-ex docker.io/centos/php-70-centos7 test --loglevel=5 &> "${WORK_DIR}/s2i-git-proto.log"
check_result $? "${WORK_DIR}/s2i-git-proto.log"

test_debug "s2i build with runtime image"
s2i build --ref=10.x --context-dir=helloworld https://github.com/wildfly/quickstart docker.io/openshift/wildfly-101-centos7 test-jee-app-thin --runtime-image=docker.io/openshift/wildfly-101-centos7 &> "${WORK_DIR}/s2i-runtime-image.log"
check_result $? "${WORK_DIR}/s2i-runtime-image.log"

test_debug "s2i build with Dockerfile output"
s2i build https://github.com/sclorg/cakephp-ex docker.io/centos/php-70-centos7 --as-dockerfile=${WORK_DIR}/asdockerfile/Dockerfile --loglevel=5 >& "${WORK_DIR}/s2i-dockerfile.log"
check_result $? "${WORK_DIR}/s2i-dockerfile.log"


test_debug "s2i build with --run==true option"
if [[ "$OSTYPE" == "cygwin" ]]; then
  ( cd hack/windows/sigintwrap && make )
  hack/windows/sigintwrap/sigintwrap 's2i build --ref=10.x --context-dir=helloworld https://github.com/wildfly/quickstart openshift/wildfly-101-centos7 test-jee-app --run=true --loglevel=5' &> "${WORK_DIR}/s2i-run.log" &
else
  s2i build --ref=10.x --context-dir=helloworld https://github.com/wildfly/quickstart docker.io/openshift/wildfly-101-centos7 test-jee-app --run=true --loglevel=5 &> "${WORK_DIR}/s2i-run.log" &
fi
S2I_PID=$!
TIME_SEC=1000
TIME_MIN=$((60 * $TIME_SEC))
max_wait=15*TIME_MIN
echo "Waiting up to ${max_wait} for the build to finish ..."
expire=$(($(time_now) + $max_wait))

set +e
while [[ $(time_now) -lt $expire ]]; do
    grep  "as a result of the --run=true option" "${WORK_DIR}/s2i-run.log"
    if [ $? -eq 0 ]; then
        echo "[INFO] Success running command s2i --run=true"

        # use sigint so that s2i post processing will remove docker container
        kill -2 "${S2I_PID}"
        NEEDKILL=""
        sleep 30
        docker ps -a | grep test-jee-app

        if [ $? -eq 1 ]; then
            echo "[INFO] Success terminating associated docker container"
            touch "${WORK_DIR}/ran-clean"
            exit 0
        else
            echo "[INFO] Associated docker container still found, review docker ps -a output above, and here is the dump of ${WORK_DIR}/s2i-run.log"
            cat "${WORK_DIR}/s2i-run.log"
            exit 1
        fi
    fi
    sleep 1
done

echo "[INFO] Problem with s2i --run=true, dumping ${WORK_DIR}/s2i-run.log"
cat "${WORK_DIR}/s2i-run.log"
set -e
exit 1

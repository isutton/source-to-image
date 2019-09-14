#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

cd "$(dirname "${BASH_SOURCE}")/.."

# https://github.com/golang/go/wiki/Modules#how-to-upgrade-and-downgrade-dependencies
#
# Updating all direct and indirect dependencies to latest minor or patch upgrades, where pre-releases
# are ignored. To list possible updates before installing, execute: "$ go list -u -m all"
go get -u=patch

#!/bin/bash

# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


set -e

DIRNAME=$(dirname $0)

PROJECT=
IMAGE_NAME="exec-wrapper"
IMAGE_TAG="staging"
AUTO_YES=

show_usage() {
  echo "Usage: ./release-app-engine-exec-wrapper.sh [flags...]" >&2
  echo "Flags:" >&2
  echo '  -n <name>: set the image name (defaults to `exec-wrapper`)' >&2
  echo '  -p <project>: set the project (defaults to current gcloud config)' >&2
  echo '  -t <tag>: the image tag to release (defaults to `staging`)' >&2
  echo '  -y: automatically confirm' >&2
}

OPTIND=1
while getopts ":n:p:t:yh" opt; do
  case ${opt} in
    n)
      IMAGE_NAME=${OPTARG}
      ;;
    p)
      PROJECT=${OPTARG}
      ;;
    t)
      IMAGE_TAG=${OPTARG}
      ;;
    y)
      AUTO_YES="true"
      ;;
    h)
      show_usage
      exit 0
      ;;
    \?)
      echo "Invalid option: -${OPTARG}" >&2
      echo >&2
      show_usage
      exit 1
      ;;
    :)
      echo "Option ${OPTARG} requires a parameter" >&2
      echo >&2
      show_usage
      exit 1
      ;;
  esac
done
shift $((OPTIND-1))

if [ -z "${PROJECT}" ]; then
  PROJECT=$(gcloud config get-value project)
  echo "**** Using project from gcloud config: ${PROJECT}" >&2
fi

WRAPPER_IMAGE=gcr.io/${PROJECT}/${IMAGE_NAME}

echo
echo "Releasing exec wrapper:"
echo "  ${WRAPPER_IMAGE}:${IMAGE_TAG}"
if [ -z "${AUTO_YES}" ]; then
  read -r -p "Ok to proceed? [Y/n] " response
  response=${response} | sed -e 's/\(.*\)/\L\1/'  # tolower
  if [[ "${response}" =~ ^(no|n)$ ]]; then
    echo "Aborting."
    exit 1
  fi
fi
echo

gcloud container images add-tag --project ${PROJECT} \
  ${WRAPPER_IMAGE}:${IMAGE_TAG} ${WRAPPER_IMAGE}:latest -q
echo "**** Tagged image ${WRAPPER_IMAGE}:${IMAGE_TAG} as latest"

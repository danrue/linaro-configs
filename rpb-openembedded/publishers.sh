#!/bin/bash

# Publish
test -d ${HOME}/bin || mkdir ${HOME}/bin
wget -q https://git.linaro.org/ci/publishing-api.git/blob_plain/HEAD:/linaro-cp.py -O ${HOME}/bin/linaro-cp.py
time python ${HOME}/bin/linaro-cp.py \
  ${DEPLOY_DIR_IMAGE}/ ${PUB_DEST}
time python ${HOME}/bin/linaro-cp.py \
  --make-link \
  $(dirname ${PUB_DEST})

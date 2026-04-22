#!/bin/sh

set -e

echo "Waiting for minio to be ready"
until mc alias set local http://minio:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} >/dev/null 2>&1; do
    sleep 2
    echo "waiting..."
done
echo "Minio ready"

mc mb --ignore-existing local/emailtemplates
mc mb --ignore-existing local/geodata

mc admin policy create local swayrider-policy /init/swayrider-policy.json
mc admin user svcacct add local ${MINIO_ROOT_USER} --name ${MINIO_SWAYRIDER_SVC_ACCT} --policy /init/swayrider-policy.json --access-key "${MINIO_SWAYRIDER_ACCESS_KEY}" --secret-key "${MINIO_SWAYRIDER_SECRET_KEY}"


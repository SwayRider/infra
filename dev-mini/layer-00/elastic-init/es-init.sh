#!/bin/bash
set -e

# analysis-icu
if ! /usr/share/elasticsearch/bin/elasticsearch-plugin list | grep -q analysis-icu; then
    echo "Installing analysis-icu"
    /usr/share/elasticsearch/bin/elasticsearch-plugin install --batch analysis-icu
else
    echo "analysis-icu already installed"
fi

exec /usr/local/bin/docker-entrypoint.sh elasticsearch

#!/usr/bin/env bash

helm package .
helm repo index --url https://rhansma.github.io/metabase-helm-chart/ .

#!/usr/bin/env bash

read -p 'Old Metabase Version: ' old_metabase_version
read -p 'New Metabase Version: ' new_metabase_version
read -p 'Old Chart Version: ' old_chart_version
read -p 'New Chart Version: ' new_chart_version

echo "s/${old_chart_version}/${new_chart_version}/g"

sed -i '' -e "s/${old_chart_version}/${new_chart_version}/g" Chart.yaml
sed -i '' -e "s/${old_metabase_version}/${new_metabase_version}/g" Chart.yaml
sed -i '' -e "s/${old_metabase_version}/${new_metabase_version}/g" values.yaml

./package.sh

git add . && git commit -m "Bump version of metabase to $new_metabase_version" && git push origin master  

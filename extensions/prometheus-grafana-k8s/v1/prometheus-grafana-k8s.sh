#!/bin/bash
set -x

echo $(date) " - Starting Script"

echo $(date) " - Waiting for API Server to start"
kubernetesStarted=1
for i in {1..600}; do
    if [ -e /usr/local/bin/kubectl ]
    then
        /usr/local/bin/kubectl cluster-info
        if [ "$?" = "0" ]
        then
            echo "kubernetes started"
            kubernetesStarted=0
            break
        fi
    else
        /usr/bin/docker ps | grep apiserver
        if [ "$?" = "0" ]
        then
            echo "kubernetes started"
            kubernetesStarted=0
            break
        fi
    fi
    sleep 1
done
if [ $kubernetesStarted -ne 0 ]
then
    echo "kubernetes did not start"
    exit 1
fi

storageclass_param() {
	kubectl get no -l kubernetes.io/role=agent -l storageprofile=managed --no-headers -o jsonpath="{.items[0].metadata.name}" > /dev/null 2> /dev/null
	if [[ $? -eq 0 ]]; then
		echo '--set server.persistentVolume.storageClass=managed-standard'
	fi
}

install_helm() {
    echo $(date) " - Downloading helm"
    curl https://storage.googleapis.com/kubernetes-helm/helm-v2.6.2-linux-amd64.tar.gz > helm-v2.6.2-linux-amd64.tar.gz
    tar -zxvf helm-v2.6.2-linux-amd64.tar.gz
    mv linux-amd64/helm /usr/local/bin/helm
    echo $(date) " - Downloading prometheus values"

    # TODO: replace this
    curl https://raw.githubusercontent.com/ritazh/acs-engine/feat-monitor/extensions/prometheus-grafana-k8s/v1/prometheus_values.yaml > prometheus_values.yaml 

    sleep 10

    echo $(date) " - helm version"
    helm version
    helm init

    echo $(date) " - helm installed"
}

update_helm() {
    echo $(date) " - Updating Helm repositories"
    helm repo update
}

install_prometheus() {
    PROM_RELEASE_NAME=monitoring
    NAMESPACE=$1

    echo $(date) " - Installing the Prometheus Helm chart"

    STORAGECLASS_PARAM=$(storageclass_param)

    echo $(date) " - Checking to see if this is an unitiated installation"
    helm get $PROM_RELEASE_NAME > /dev/null 2> /dev/null
    if [[ $? -eq 0 ]]; then
        echo $(date) " - Monitoring extension has already started"
        return 1
    else
        echo $(date) " - Initial master node extension, continuing with installation"
    fi

    helm install -f prometheus_values.yaml \
        --name $PROM_RELEASE_NAME \
        --namespace $NAMESPACE stable/prometheus $STORAGECLASS_PARAM

    PROM_POD_PREFIX="$PROM_RELEASE_NAME-prometheus-server"
    DESIRED_POD_STATE=Running

    ATTEMPTS=90
    SLEEP_TIME=10

    ITERATION=0
    while [[ $ITERATION -lt $ATTEMPTS ]]; do
        echo $(date) " - Is the prometheus server pod ($PROM_POD_PREFIX-*) running? (attempt $(( $ITERATION + 1 )) of $ATTEMPTS)"

        kubectl get po -n $NAMESPACE --no-headers |
            awk '{print $1 " " $3}' |
            grep $PROM_POD_PREFIX |
            grep -q $DESIRED_POD_STATE

        if [[ $? -eq 0 ]]; then
            echo $(date) " - $PROM_POD_PREFIX-* is $DESIRED_POD_STATE"
            break
        fi

        ITERATION=$(( $ITERATION + 1 ))
        sleep $SLEEP_TIME
    done
}

install_grafana() {
    GF_RELEASE_NAME=dashboard
    NAMESPACE=$1

    echo $(date) " - Installing the Grafana Helm chart"
    helm install --name $GF_RELEASE_NAME --namespace $NAMESPACE stable/grafana $(storageclass_param)

    GF_POD_PREFIX="$GF_RELEASE_NAME-grafana"
    DESIRED_POD_STATE=Running

    ATTEMPTS=90
    SLEEP_TIME=10

    ITERATION=0
    while [[ $ITERATION -lt $ATTEMPTS ]]; do
        echo $(date) " - Is the grafana pod ($GF_POD_PREFIX-*) running? (attempt $(( $ITERATION + 1 )) of $ATTEMPTS)"

        kubectl get po -n $NAMESPACE --no-headers |
            awk '{print $1 " " $3}' |
            grep $GF_POD_PREFIX |
            grep -q $DESIRED_POD_STATE

        if [[ $? -eq 0 ]]; then
            echo $(date) " - $GF_POD_PREFIX-* is $DESIRED_POD_STATE"
            break
        fi

        ITERATION=$(( $ITERATION + 1 ))
        sleep $SLEEP_TIME
    done
}

# Deploy container

NAMESPACE=default
K8S_SECRET_NAME=dashboard-grafana
DS_TYPE=prometheus
DS_NAME=prometheus1

PROM_URL=http://monitoring-prometheus-server

install_helm
update_helm
install_prometheus $NAMESPACE
if [[ $? -eq 1 ]]; then
    echo $(date) " - Not the first master to attempt monitoring initialization. Exiting"
    exit 1
fi
install_grafana $NAMESPACE

sleep 5

echo $(date) " - Creating the Prometheus datasource in Grafana"
GF_USER_NAME=$(kubectl get secret $K8S_SECRET_NAME -o jsonpath="{.data.grafana-admin-user}" | base64 --decode)
echo $GF_USER_NAME
GF_PASSWORD=$(kubectl get secret $K8S_SECRET_NAME -o jsonpath="{.data.grafana-admin-password}" | base64 --decode)
echo $GF_PASSWORD
GF_URL=$(kubectl get svc -l "app=dashboard-grafana,component=grafana" -o jsonpath="{.items[0].spec.clusterIP}")
echo $GF_URL

echo retrieving current data sources...
CURRENT_DS_LIST=$(curl -s --user "$GF_USER_NAME:$GF_PASSWORD" "$GF_URL/api/datasources")
echo $CURRENT_DS_LIST | grep -q "\"name\":\"$DS_NAME\""
if [[ $? -eq 0 ]]; then
    echo data source $DS_NAME already exists
    echo $CURRENT_DS_LIST | python -m json.tool
    exit 0
fi

echo data source $DS_NAME does not exist, creating...
DS_RAW=$(cat << EOF
{
    "name": "$DS_NAME",
    "type": "$DS_TYPE",
    "url": "$PROM_URL",
    "access": "proxy"
}
EOF
)



ATTEMPTS=90
SLEEP_TIME=10

ITERATION=0
while [[ $ITERATION -lt $ATTEMPTS ]]; do
    echo $(date) " - Is the grafana api running? (attempt $(( $ITERATION + 1 )) of $ATTEMPTS)"

    response=$(curl \
        -X POST \
        --user "$GF_USER_NAME:$GF_PASSWORD" \
        -H "Content-Type: application/json" \
        -d "$DS_RAW" \
        "$GF_URL/api/datasources")

    if [[ $response == *"Datasource added"* ]]; then
        echo $(date) " - Data source added successfully"
        break
    fi

    ITERATION=$(( $ITERATION + 1 ))
    sleep $SLEEP_TIME
done

echo $(date) " - Creating the Kubernetes dashboard in Grafana"

cat << EOF > sanitize_dashboard.py
#!/usr/bin/python3

import fileinput
import json

dashboard = json.loads(''.join(fileinput.input()))
dashboard.pop('__inputs')
dashboard.pop('__requires')
print(json.dumps(dashboard).replace('\${DS_PROMETHEUS}', 'prometheus1'))

EOF

chmod u+x sanitize_dashboard.py

DB_RAW=$(cat << EOF
{
    "dashboard": $(curl -sL "https://grafana.com/api/dashboards/315/revisions/3/download" | ./sanitize_dashboard.py),
    "overwrite": false
}
EOF
)

curl \
    -X POST \
    --user "$GF_USER_NAME:$GF_PASSWORD" \
    -H "Content-Type: application/json" \
    -d "$DB_RAW" \
    "$GF_URL/api/dashboards/db"

echo $(date) " - Script complete"

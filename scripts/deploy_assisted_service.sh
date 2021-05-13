#!/usr/bin/env bash
set -euo pipefail

source scripts/utils.sh

export SERVICE_NAME=assisted-service
export SERVICE_URL=$(get_main_ip)
export AUTH_TYPE=${AUTH_TYPE:-none}
export WITH_AMS_SUBSCRIPTIONS=${WITH_AMS_SUBSCRIPTIONS:-false}
export NAMESPACE=${NAMESPACE:-assisted-installer}
export SERVICE_PORT=$(( 6000 + $NAMESPACE_INDEX ))
export SERVICE_BASE_URL=${SERVICE_BASE_URL:-"http://${SERVICE_URL}:${SERVICE_PORT}"}
export EXTERNAL_PORT=${EXTERNAL_PORT:-y}
export OCP_SERVICE_PORT=$(( 7000 + $NAMESPACE_INDEX ))
export OPENSHIFT_INSTALL_RELEASE_IMAGE=${OPENSHIFT_INSTALL_RELEASE_IMAGE:-}
export ENABLE_KUBE_API=${ENABLE_KUBE_API:-false}
export ENABLE_KUBE_API_CMD="ENABLE_KUBE_API=${ENABLE_KUBE_API}"
export OPENSHIFT_VERSIONS=${OPENSHIFT_VERSIONS:-}
export OPENSHIFT_VERSIONS_CMD=""

if [[ "${ENABLE_KUBE_API}" == "true" || "${DEPLOY_TARGET}" == "operator" && -z "${OPENSHIFT_VERSIONS}" ]]; then
    # Supporting version 4.8 for kube-api
    OPENSHIFT_VERSIONS=$(cat assisted-service/default_ocp_versions.json |
       jq -rc 'with_entries(.key = "4.8") | with_entries(
           {key: .key, value: .value})')
    json_template=\''%s'\'
    OPENSHIFT_VERSIONS_CMD="OPENSHIFT_VERSIONS=$(printf "${json_template}" "${OPENSHIFT_VERSIONS}")"
fi

mkdir -p build

if [ "${OPENSHIFT_INSTALL_RELEASE_IMAGE}" != "" ]; then
    ./assisted-service/tools/handle_ocp_versions.py --src ./assisted-service/default_ocp_versions.json \
        --dest ./assisted-service/default_ocp_versions.json --ocp-override ${OPENSHIFT_INSTALL_RELEASE_IMAGE}

    if [ "${DEPLOY_TARGET}" == "onprem" ]; then
        if [ -x "$(command -v docker)" ]; then
            make -C assisted-service/ generate-configuration
        else
            ln -s $(which podman) /usr/bin/docker
            make -C assisted-service/ generate-configuration
            rm -f /usr/bin/docker
        fi
    fi
fi

if [ "${DEPLOY_TARGET}" == "onprem" ]; then
    if [ -n "${INSTALLER_IMAGE:-}" ]; then
        echo "INSTALLER_IMAGE=${INSTALLER_IMAGE}" >> assisted-service/onprem-environment
    fi
    if [ -n "${CONTROLLER_IMAGE:-}" ]; then
        echo "CONTROLLER_IMAGE=${CONTROLLER_IMAGE}" >> assisted-service/onprem-environment
    fi
    if [ -n "${AGENT_DOCKER_IMAGE:-}" ]; then
        echo "AGENT_DOCKER_IMAGE=${AGENT_DOCKER_IMAGE}" >> assisted-service/onprem-environment
    fi
    if [ -n "$PUBLIC_CONTAINER_REGISTRIES" ]; then
        sed -i "s|PUBLIC_CONTAINER_REGISTRIES=.*|PUBLIC_CONTAINER_REGISTRIES=${PUBLIC_CONTAINER_REGISTRIES}|" assisted-service/onprem-environment
    fi
    sed -i "s/SERVICE_BASE_URL=http:\/\/127.0.0.1/SERVICE_BASE_URL=http:\/\/${ASSISTED_SERVICE_HOST}/" assisted-service/onprem-environment
    echo "HW_VALIDATOR_MIN_DISK_SIZE_GIB=20" >> assisted-service/onprem-environment
    make -C assisted-service/ deploy-onprem
elif [ "${DEPLOY_TARGET}" == "ocp" ]; then
    print_log "Starting port forwarding for deployment/$SERVICE_NAME on port $OCP_SERVICE_PORT"
    add_firewalld_port $OCP_SERVICE_PORT

    SERVICE_BASE_URL=http://$SERVICE_URL:$OCP_SERVICE_PORT
    IP_NODEPORT=$(skipper run "scripts/ocp.sh deploy_service $OCP_KUBECONFIG $SERVICE $SERVICE_NAME $SERVICE_BASE_URL $NAMESPACE $CONTROLLER_OCP" 2>&1 | tee /dev/tty | tail -1)
    read -r CLUSTER_VIP SERVICE_NODEPORT <<< "$IP_NODEPORT"
    print_log "CLUSTER_VIP is ${CLUSTER_VIP}, SERVICE_NODEPORT is ${SERVICE_NODEPORT}"

    wait_for_url_and_run "$SERVICE_BASE_URL" "spawn_port_forwarding_command $SERVICE_NAME $OCP_SERVICE_PORT $NAMESPACE $NAMESPACE_INDEX $OCP_KUBECONFIG ocp $CLUSTER_VIP $SERVICE_NODEPORT"
    print_log "${SERVICE_NAME} can be reached at ${SERVICE_BASE_URL}"
elif [ "${DEPLOY_TARGET}" == "operator" ]; then
    # This nginx would listen to http on OCP_SERVICE_PORT and it would proxy_pass it to the actual route.
    export SERVICE_BASE_URL=http://${SERVICE_URL}:${OCP_SERVICE_PORT}
    add_firewalld_port ${OCP_SERVICE_PORT}

    # TODO: Find a way to get the route dest dynamically.
    # Currently it's not possible since it would be available only after the operator would be deployed
    # The deploy.sh script would wait for the operator to succeed - so we need to have the LB before that.
    # ROUTE=$(kubectl get routes -n assisted-installer --no-headers | awk '{print $2}')

    ROUTE=assisted-service-assisted-installer.apps.test-infra-cluster-assisted-installer.redhat.com

    tee << EOF ${HOME}/.test-infra/etc/nginx/conf.d/http_localhost.conf
upstream upstream_${SERVICE_URL//./_} {
    server ${ROUTE}:443;
}

server {
    listen ${SERVICE_URL}:${OCP_SERVICE_PORT};

    location / {
        proxy_pass https://upstream_${SERVICE_URL//./_};
        proxy_set_header Host ${ROUTE};
    }
}
EOF

    export DISKS="${LSO_DISKS:-}"
    export ASSISTED_NAMESPACE=${NAMESPACE}
    export SERVICE_IMAGE=${SERVICE}
    export STORAGE_CLASS_NAME="localblock-sc"

    INSTALL_LSO=false ./assisted-service/deploy/operator/deploy.sh
    echo "Installation of Assisted Install operator passed successfully!"
else
    print_log "Updating assisted_service params"
    skipper run discovery-infra/update_assisted_service_cm.py
    (cd assisted-service/ && skipper --env-file ../skipper.env run "make deploy-all" ${SKIPPER_PARAMS} $ENABLE_KUBE_API_CMD $OPENSHIFT_VERSIONS_CMD DEPLOY_TAG=${DEPLOY_TAG} DEPLOY_MANIFEST_PATH=${DEPLOY_MANIFEST_PATH} DEPLOY_MANIFEST_TAG=${DEPLOY_MANIFEST_TAG} NAMESPACE=${NAMESPACE} AUTH_TYPE=${AUTH_TYPE})

    add_firewalld_port $SERVICE_PORT

    print_log "Starting port forwarding for deployment/${SERVICE_NAME} on port $SERVICE_PORT"
    wait_for_url_and_run ${SERVICE_BASE_URL} "spawn_port_forwarding_command $SERVICE_NAME $SERVICE_PORT $NAMESPACE $NAMESPACE_INDEX $KUBECONFIG minikube"
    print_log "${SERVICE_NAME} can be reached at ${SERVICE_BASE_URL} "
    print_log "Done"
fi

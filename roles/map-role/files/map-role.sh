#!/bin/bash
####################################################################################################
# Install Platform9 On-Prem Kubernetes for Bare-Metal
####################################################################################################

basedir=$(dirname $0)
platform=""
flag_installKubectl=0
flag_attachCluster=0
config_file=${basedir}/isv.conf

# set defaults
cluster_name="defaultCluster"

usage() {
  echo -e "usage: `basename $0` <ctrl_ip> <role> <host_id> <admin_user> <admin_password> [args]\n"
  echo "-k               : download/install/configure Kubectl from management server"
  echo "-a               : attach node to cluster"
  echo
  exit 1
}

assert() {
  if [ $# -eq 1 ]; then echo "ASSERT: ${1}"; fi
  exit 1
}

validate_platform() {
  # check if running CentOS 7.4
  if [ -r /etc/centos-release ]; then
    release=$(cat /etc/centos-release | cut -d ' ' -f 4)
    if [[ ! "${release}" == 7.4.* ]]; then assert "unsupported CentOS release: ${release}"; fi
    platform="centos"
    host_os_info=$(cat /etc/centos-release)
  elif [ -r /etc/lsb-release ]; then
    release=$(cat /etc/lsb-release | grep ^DISTRIB_RELEASE= /etc/lsb-release | cut -d '=' -f2)
    if [[ ! "${release}" == 16.04* ]]; then assert "unsupported CentOS release: ${release}"; fi
    platform="ubuntu"
    ubuntu_release=$(cat /etc/lsb-release | grep ^DISTRIB_RELEASE | cut -d = -f2)
    host_os_info="${platform} ${ubuntu_release}"
  else
    assert "unsupported platform"
  fi
}

banner() {
  if [ $# -ge 1 ]; then title=${1}; fi
  if [ $# -eq 2 -a "${2}" == "-n" ]; then echo; fi
  echo "********************************************************************************"
  echo "*** ${title}"
  echo "********************************************************************************"
}

wait_n() {
  time_to_wait=10
  if [ $# -eq 1 ]; then time_to_wait=${1}; fi

  local cnt=0
  while [ ${cnt} -lt ${time_to_wait} ]; do
    echo -n "."
    sleep 1
    ((cnt++))
  done
  echo
}

attach_node() {
  export LD_LIBRARY_PATH="/opt/pf9/python/pf9-lib:/opt/pf9/python/pf9-hostagent-lib:${LD_LIBRARY_PATH}"
  export PYTHONPATH="/opt/pf9/python/lib/python2.7:${PYTHONPATH}"
  if [ ! -r /opt/pf9/setupd/bin/attach-node ]; then assert "attach-node not found"; fi
  /opt/pf9/setupd/bin/attach-node --mgmt-ip ${ctrl_ip} --admin-user ${admin_user} --admin-password ${admin_password} \
      --hostid ${host_id} --cluster-name ${cluster_name}
  if [ $? -ne 0 ]; then return 1; fi
}

## validate commandline
if [ $# -lt 5 ]; then usage; fi
ctrl_ip=${1}
role=${2}
host_id=${3}
admin_user=${4}
admin_password=${5}

## process optional arguments
shift 5
while [ $# -gt 0 ]; do
  case ${1} in
  -k)
    flag_installKubectl=1
    shift
    ;;
  *)
    usage
    ;;
  esac
done

## validate role
case ${role} in
pf9-kube|pf9-ostackhost|pf9-ostackhost-neutron)
  ;;
*)
  assert "invalid role: ${role}"
esac

## validate logged in as root
uid=$(id -u)
if [ ${uid} -ne 0 ]; then assert "this operation must be run as root"; fi

## set auth url
auth_url=https://${ctrl_ip}/keystone/v3

## validate platform (CentOS 7.4 or Ubuntu 16.04)
validate_platform

####################################################################################################
## Install Kubctl
####################################################################################################
if [ ${flag_installKubectl} -eq 1 ]; then
  banner "Installing Kubectl"
  curl -o /usr/bin/kubectl -LO https://storage.googleapis.com/kubernetes-release/release/v1.8.4/bin/linux/amd64/kubectl
  if [ $? -ne 0 ]; then exit 1; fi
  chmod 0755 /usr/bin/kubectl
  echo -e "\nExecuting: /opt/pf9/setupd/bin/qb.py --admin-user ${admin_user} --admin-password ${admin_password} \
       --mgmt-ip ${ctrl_ip}  get-kubeconfig --name ${cluster_name}"
  /opt/pf9/setupd/bin/qb.py --admin-user ${admin_user} --admin-password ${admin_password} \
      --mgmt-ip ${ctrl_ip}  get-kubeconfig --name ${cluster_name} > /tmp/kubeconfig
  if [ $? -ne 0 ]; then
    cat /tmp/kubeconfig
    exit 1
  fi
  echo -e "Executing: kubectl --kubeconfig=/tmp/kubeconfig cluster-info"
  kubectl --kubeconfig=/tmp/kubeconfig cluster-info
  exit 0
fi

####################################################################################################
## Attach to Cluster
####################################################################################################
if [ ${flag_attachCluster} -eq 1 ]; then
  attach_node
  exit 0
fi

####################################################################################################
# Get Keystone Token
####################################################################################################
banner "Getting Keystone Token" -n
token=`curl -k -i -H "Content-Type: application/json" ${auth_url}/auth/tokens?nocatalog \
    -d "{ \"auth\": { \"identity\": { \"methods\": [\"password\"], \"password\": { \"user\": { \"name\": \"${admin_user}\", \"domain\": {\"id\": \"default\"}, \"password\": \"${admin_password}\" } } }, \"scope\": { \"project\": { \"name\": \"service\", \"domain\": {\"id\": \"default\"}}}}}" 2>/dev/null | grep -i ^X-Subject-Token | awk -F : '{print $2}' | sed -e 's/ //g' | sed -e 's/\r//g'`

####################################################################################################
# Wait for Host Agent to Register
####################################################################################################
#banner "Waiting for Host Agent to Register" -n
#wait_n 45
#curl -k -i -H "Content-Type: application/json" -H "X-Auth-Token: ${token}" https://${ctrl_ip}/resmgr/v1/hosts/${host_id}; echo
#if [ $? -ne 0 ]; then exit 1; fi

####################################################################################################
# Assign Role : pf9-kube
####################################################################################################
if [ "${role}" == "pf9-kube" ]; then
  banner "Assigning Role : ${role}" -n
  curl -v -k -i -X PUT -H "Content-Type: application/json" -H "X-Auth-Token: ${token}" \
      -d "{}" https://${ctrl_ip}/resmgr/v1/hosts/${host_id}/roles/${role}
  if [ $? -ne 0 ]; then exit 1; fi

  # Attach Node to Cluster
  # NOTE: If k8s containers fail to start, run: 'systemctl restart pf9-kubelet.service'
  banner "Attaching Node to Cluster" -n
  wait_n 60
  attach_node
  if [ $? -ne 0 ]; then exit 1; fi
fi

####################################################################################################
# Assign Role : pf9-ostackhost
####################################################################################################
if [ "${role}" == "pf9-ostackhost" ]; then
  banner "Assigning Role : ${role}" -n
  curl -v -k -i -X PUT -H "Content-Type: application/json" -H "X-Auth-Token: ${token}" \
      -d "{}" https://${ctrl_ip}/resmgr/v1/hosts/${host_id}/roles/${role}
  if [ $? -ne 0 ]; then exit 1; fi
fi

####################################################################################################
# Assign Role : pf9-ostackhost
####################################################################################################
if [ "${role}" == "pf9-ostackhost-neutron" ]; then
  banner "Assigning Role : ${role}" -n
  json_data="{\"cluster_ip\": {\"default\": \"\", \"path\": \"config/nova/PF9\"}, \"reclaim_instance_interval\": {\"default\": \"0\", \"path\": \"config/nova/DEFAULT\"}, \"find_orphaned_vms_interval\": {\"default\": \"-1\", \"path\": \"config/nova/PF9\"}, \"cpu_allocation_ratio\": {\"default\": \"0.0\", \"path\": \"config/nova/DEFAULT\"}, \"instances_path\": {\"default\": \"/opt/pf9/data/instances/\", \"path\": \"config/nova/DEFAULT\"}, \"novncproxy_base_url\": {\"default\": \"http://localhost:6080/vnc_auto.html\", \"path\": \"config/nova/DEFAULT\"}, \"consul_ip\": {\"default\": \"\", \"path\": \"config/nova/PF9\"}, \"images_type\": {\"default\": \"default\", \"path\": \"config/nova/libvirt\"}, \"ram_allocation_ratio\": {\"default\": \"0.0\", \"path\": \"config/nova/DEFAULT\"}, \"ssl_only\": {\"default\": \"False\", \"path\": \"config/nova/DEFAULT\"}}"
  echo curl -v -k -i -X PUT -H "Content-Type: application/json" -H "X-Auth-Token: ${token}" \
      -d ${json_data} https://${ctrl_ip}/resmgr/v1/hosts/${host_id}/roles/${role}
  if [ $? -ne 0 ]; then exit 1; fi
fi

echo -e "\n[ COMPLETE ]\n"
exit 0

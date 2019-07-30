#!/bin/bash
set -e

function kv {
  # Note the 'cas' command puts a value in the KV store if it is empty
  local key
  local value
  read -r key value <<< "$*"
  log "Adding key ${key} with value ${value} to KV store."

  if [[ "${KV_VERSION}" -eq "v3" ]]; then
    log "etcdctl ${ETCDCTL_OPTS[@]} ${KV_TLS[@]} put /${CLUSTER_PATH}${key} ${value}"
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" put "/${CLUSTER_PATH}""${key}" "${value}"
  else
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" set "/${CLUSTER_PATH}""${key}" "${value}" || log "Value is already set"
  fi

  log "test"
}

function populate_kv {
  if [[ -z $KV_TYPE ]]; then
    echo "Please specify a KV store, e.g: etcd."
    exit 1
  fi
  case "$KV_TYPE" in
    etcd)

      if [[ "${KV_VERSION}" -ne "v3" ]]; then
        etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mkdir "/${CLUSTER_PATH}/client_host" || log "client_host already exists"
      fi
      # if ceph.defaults found in /etc/ceph/ use that
      if [[ -e "/etc/ceph/ceph.defaults" ]]; then
        local defaults_path="/etc/ceph/ceph.defaults"
      else
        # else use defaults
        defaults_path="/opt/ceph-container/etc/ceph.defaults"
      fi
      # read defaults file, grab line with key<space>value without comment #
      grep '^.* .*' "$defaults_path" | grep -v '#' | while read -r line; do
      kv "$line"
      done
      ;;
    *)
      echo "$KV_TYPE: KV store is not supported."
      exit 1
      ;;
  esac
}

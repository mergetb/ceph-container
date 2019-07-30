#!/bin/bash
set -e

sed -r "s/@CLUSTER@/${CLUSTER:-ceph}/g" \
    /etc/confd/conf.d/ceph.conf.toml.in > /etc/confd/conf.d/ceph.conf.toml

function get_mon_config {

  local etcdSetCmd="set"
  if [[ "$KV_VERSION" -eq "v3" ]]; then
    etcdSetCmd="put"
  fi

  # Make sure root dirs are present for confd to work
  for dir in auth global mon mds osd client; do
    if [[ "$KV_VERSION" -ne "v3" ]]; then
      etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mkdir "/${CLUSTER_PATH}"/"$dir" > /dev/null 2>&1  || log "'$dir' key already exists"
    fi
  done

  printf "etcdctl ${ETCDCTL_OPTS[@]} ${KV_TLS[@]} cmd /${CLUSTER_PATH}/$dir\n"

  log "Adding Mon Host - ${MON_NAME}."
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "${etcdSetCmd}" "/${CLUSTER_PATH}"/mon_host/"${MON_NAME}" "${MON_IP}"

  # Acquire lock to not run into race conditions with parallel bootstraps
  if [[ "$KV_VERSION" -eq "v3" ]]; then
   local timeout=0
   while [ $timeout -lt 60 ]; do
      # TODO txn
      local val=`etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" get --print-value-only "/${CLUSTER_PATH}/lock"`
      echo $val
      if [[ "$val" == "" ]]; then
        etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" put "/${CLUSTER_PATH}/lock" "${MON_NAME}"
      elif [[ "$val" == "${MON_NAME}" ]]; then
        break
      fi
      echo "Configuration is locked by another host. Retry: " $timeout
      sleep 1
      timeout=$((timeout+1))
    done
  else
    echo "version: $KV_VERSION"
    until etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" mk "/${CLUSTER_PATH}"/lock "$MON_NAME" --ttl 60; do
      echo "Configuration is locked by another host. Waiting..."
      sleep 1
    done
  fi

  # Now we have the lock!

  # Update config after initial mon creation
  local getCommand="get"
  if [[ "$KV_VERSION" -eq "v3" ]]; then
    getCommand="get --print-value-only"
  fi
  if etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "$getCommand" "/${CLUSTER_PATH}"/monSetupComplete; then
    log "Configuration found for cluster ${CLUSTER}. Writing to disk."

    get_config

    log "Adding mon/admin Keyrings."
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "$getCommand" "/${CLUSTER_PATH}"/adminKeyring > "$ADMIN_KEYRING"
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "$getCommand" "/${CLUSTER_PATH}"/monKeyring > "$MON_KEYRING"

    if [ ! -f "$MONMAP" ]; then
      log "Monmap is missing. Adding initial monmap..."
      etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "$getCommand" "/${CLUSTER_PATH}"/monmap | uudecode -o "$MONMAP"
    fi

    log "Trying to get the most recent monmap..."
    if timeout 5 ceph "${CLI_OPTS[@]}" mon getmap -o "$MONMAP"; then
      log "Monmap successfully retrieved. Updating KV store."
      uuencode "$MONMAP" - | etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "${etcdSetCmd}" "/${CLUSTER_PATH}"/monmap
    else
      log "Peers not found, using initial monmap."
    fi

  else
    # Create initial Mon, keyring
    log "No configuration found for cluster ${CLUSTER}. Generating."

    local fsid
    fsid=`etcdctl ${ETCDCTL_OPTS[@]} ${KV_TLS[@]} $getCommand /${CLUSTER_PATH}/auth/fsid`
    log "ETCD FSID: $fsid"
    if [[ -z "$fsid" ]]; then
      fsid=$(uuidgen)
    fi
    log "FSID: $fsid"
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "${etcdSetCmd}" "/${CLUSTER_PATH}/auth/fsid" "${fsid}"

    until confd -onetime -backend "${KV_TYPE}${KV_VERSION}" -node "${CONFD_NODE_SCHEMA}""${KV_IP}":"${KV_PORT}" "${CONFD_KV_TLS[@]}" -prefix="/${CLUSTER_PATH}/"; do
      log "Waiting for confd to write initial templates..."
      sleep 1
    done

    log "Creating Keyrings."
    if [ -z "$ADMIN_SECRET" ]; then
      # Automatically generate administrator key
      CLI+=(--gen-key)
    else
      # Generate custom provided administrator key
      CLI+=("--add-key=$ADMIN_SECRET")
    fi
    ceph-authtool "$ADMIN_KEYRING" --create-keyring "${CLI[@]}" -n client.admin --set-uid=0 --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'
    ceph-authtool "$MON_KEYRING" --create-keyring --gen-key -n mon. --cap mon 'allow *'

    for item in ${OSD_BOOTSTRAP_KEYRING}:Osd ${MDS_BOOTSTRAP_KEYRING}:Mds ${RGW_BOOTSTRAP_KEYRING}:Rgw ${RBD_MIRROR_BOOTSTRAP_KEYRING}:Rbd; do
      local array
      IFS=" " read -r -a array <<< "${item//:/ }"
      local keyring=${array[0]}
      local bootstrap="bootstrap-${array[1]}"
      ceph-authtool "$keyring" --create-keyring --gen-key -n client."$(to_lowercase "$bootstrap")" --cap mon "allow profile $(to_lowercase "$bootstrap")"
      bootstrap="bootstrap${array[1]}Keyring"
      etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "${etcdSetCmd}" "/${CLUSTER_PATH}"/"${bootstrap}" < "$keyring"
    done

    log "Creating Monmap."
    monmaptool --create --add "${MON_NAME}" "${MON_IP}:6789" --fsid "${fsid}" "$MONMAP"

    log "Importing Keyrings and Monmap to KV."
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "${etcdSetCmd}" "/${CLUSTER_PATH}"/monKeyring < "$MON_KEYRING"
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "${etcdSetCmd}" "/${CLUSTER_PATH}"/adminKeyring < "$ADMIN_KEYRING"
    chown "${CHOWN_OPT[@]}" ceph. "$MON_KEYRING" "$ADMIN_KEYRING"

    uuencode "$MONMAP" - | etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "${etcdSetCmd}" "/${CLUSTER_PATH}"/monmap

    log "Completed initialization for ${MON_NAME}."
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "${etcdSetCmd}" "/${CLUSTER_PATH}"/monSetupComplete true
  fi

  # Remove lock for other clients to install
  log "Removing lock for ${MON_NAME}."
  if [[ "$KV_VERSION" -eq "v3" ]]; then
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" del "/${CLUSTER_PATH}"/lock || true
  else
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" rm "/${CLUSTER_PATH}"/lock || true
  fi
}

function import_bootstrap_keyrings {

  local getCommand="get"
  if [[ "$KV_VERSION" -eq "v3" ]]; then
    getCommand="get --print-value-only"
  fi

  for item in ${OSD_BOOTSTRAP_KEYRING}:Osd ${MDS_BOOTSTRAP_KEYRING}:Mds ${RGW_BOOTSTRAP_KEYRING}:Rgw ${RBD_MIRROR_BOOTSTRAP_KEYRING}:Rbd; do
    local array
    IFS=" " read -r -a array <<< "${item//:/ }"
    local keyring
    keyring=${array[0]}
    local bootstrap_keyring
    bootstrap_keyring="bootstrap${array[1]}Keyring"
    etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "$getCommand" "/${CLUSTER_PATH}"/"${bootstrap_keyring}" > "$keyring"
    chown "${CHOWN_OPT[@]}" ceph. "$keyring"
  done
}

function get_config {

  local getCommand="get"
  if [[ "$KV_VERSION" -eq "v3" ]]; then
    getCommand="get --print-value-only"
  fi

  until etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "$getCommand" "/${CLUSTER_PATH}"/monSetupComplete; do
    log "OSD: Waiting for monitor setup to complete..."
    sleep 5
  done

  until confd -onetime -backend "${KV_TYPE}${KV_VERSION}" -node "${CONFD_NODE_SCHEMA}""${KV_IP}":"${KV_PORT}" "${CONFD_KV_TLS[@]}" -prefix="/${CLUSTER_PATH}/"; do
    log "Waiting for confd to update templates..."
    sleep 1
  done

  log "Adding bootstrap keyrings."
  import_bootstrap_keyrings
}

function get_admin_key {

  local getCommand="get"
  if [[ "$KV_VERSION" -eq "v3" ]]; then
    getCommand="get --print-value-only"
  fi

  log "Retrieving the admin key."
  etcdctl "${ETCDCTL_OPTS[@]}" "${KV_TLS[@]}" "$getCommand" "/${CLUSTER_PATH}"/adminKeyring > /etc/ceph/"${CLUSTER}".client.admin.keyring
}

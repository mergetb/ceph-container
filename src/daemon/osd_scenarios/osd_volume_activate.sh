#!/bin/bash
set -e
set -x

function osd_volume_simple {
  # Find the devices used by ceph-disk
  DEVICES=$(ceph-volume inventory --format json | $PYTHON -c 'import sys, json; print(" ".join([d.get("path") for d in json.load(sys.stdin) if "Used by ceph-disk" in d.get("rejected_reasons")]))')

  # Scan devices with ceph data partition
  for device in ${DEVICES}; do
    if parted --script "${device}" print | grep -qE '^ 1.*ceph data'; then
      if [[ "${device}" =~ ^/dev/(cciss|nvme) ]]; then
        device+="p"
      fi
      ceph-volume simple scan ${device}1 --force || true
    fi
  done

  # Find the OSD json file associated to the ID
  OSD_JSON=$(grep -l "whoami\": ${OSD_ID}$" /etc/ceph/osd/*.json)
  if [ -z "${OSD_JSON}" ]; then
    log "OSD id ${OSD_ID} does not exist"
    exit 1
  fi

  # Activate the OSD
  # The command can fail so if it does, let's output the ceph-volume logs
  if ! ceph-volume simple activate --file ${OSD_JSON} --no-systemd; then
    cat /var/log/ceph
    exit 1
  fi
}

function osd_volume_lvm {
  # Find the OSD FSID from the OSD ID
  OSD_FSID="$(echo "$CEPH_VOLUME_LIST_JSON" | $PYTHON -c "import sys, json; print(json.load(sys.stdin)[\"$OSD_ID\"][0][\"tags\"][\"ceph.osd_fsid\"])")"

  # Find the OSD type
  OSD_TYPE="$(echo "$CEPH_VOLUME_LIST_JSON" | $PYTHON -c "import sys, json; print(json.load(sys.stdin)[\"$OSD_ID\"][0][\"type\"])")"

  # Discover the objectstore
  if [[ "data journal" =~ $OSD_TYPE ]]; then
    OSD_OBJECTSTORE=(--filestore)
  elif [[ "block wal db" =~ $OSD_TYPE ]]; then
    OSD_OBJECTSTORE=(--bluestore)
  else
    log "Unable to discover osd objectstore for OSD type: $OSD_TYPE"
    exit 1
  fi

  # Activate the OSD
  # The command can fail so if it does, let's output the ceph-volume logs
  if ! ceph-volume lvm activate --no-systemd "${OSD_OBJECTSTORE[@]}" "${OSD_ID}" "${OSD_FSID}"; then
    cat /var/log/ceph
    exit 1
  fi
}

function osd_volume_activate {
  : "${OSD_ID:?Give me an OSD ID to activate, eg: -e OSD_ID=0}"

  CEPH_VOLUME_LIST_JSON="$(ceph-volume lvm list --format json)"

  if echo "$CEPH_VOLUME_LIST_JSON" | $PYTHON -c "import sys, json; print(json.load(sys.stdin)[\"$OSD_ID\"])" &> /dev/null; then
    osd_volume_lvm
  else
    osd_volume_simple
  fi

  log "SUCCESS"
  # This ensures all resources have been unmounted after the OSD has exited
  # We define `sigterm_cleanup_post` here because:
  # - we want to 'protect' the following `exec` in particular.
  # - having the cleaning code just next to the concerned function in the same file is nice.
  function sigterm_cleanup_post {
    local ceph_mnt
    ceph_mnt=$(findmnt --nofsroot --noheadings --output SOURCE --submounts --target /var/lib/ceph/osd/ | grep '^/')
    for mnt in $ceph_mnt; do
      log "osd_volume_activate: Unmounting $mnt"
      umount "$mnt" || (log "osd_volume_activate: Failed to umount $mnt"; lsof "$mnt")
    done
  }
  /usr/bin/ceph-osd "${DAEMON_OPTS[@]}" -i "${OSD_ID}"
}


function osd_volume_create {
  if [[ -z "${OSD_DEVICE}" ]];then
    log "ERROR- You must provide a device to build your OSD ie: /dev/sdb"
    exit 1
  fi

  if [[ ! -e "${OSD_DEVICE}" ]]; then
    log "ERROR- The device pointed by OSD_DEVICE ($OSD_DEVICE) doesn't exist !"
    exit 1
  fi

  # ceph volume requires that we have have some mounts to the host, especially
  # since this creates the systemd files

  ceph-volume lvm zap  "${OSD_DEVICE}" --destroy
  ceph-volume lvm create --bluestore --data "${OSD_DEVICE}" --no-systemd

  # ceph-volume creates a tmpfs to store this data, so we are going to
  # create a new directory, move all the data from that tmp place
  # umount the directory, then copy the data back in place.

  ceph_volume=$(ceph-volume inventory $OSD_DEVICE --format json)
  ceph_osd_id=$(echo $ceph_volume | jq '.["lvs"][0]."osd_id" | tonumber')

  # tmp dir is just holding our data while we move it out of tmpfs dir
  tmp_dir="/tmp/osd-$ceph_osd_id"
  # osd dir is the location were the data lives, that we want to live
  osd_dir="/var/lib/ceph/osd/$CLUSTER-$ceph_osd_id"

  # create tmp dir, move data out of tmpfs into tmp, then umount tmfs
  # and move data back into data dir
  mkdir -p $tmp_dir
  cp -r "$osd_dir/"* "$tmp_dir/"
  umount "$osd_dir"
  cp -r "$tmp_dir/"* "$osd_dir/"

}


# lots of assumptions
function osd_daemon_volume {

  if [[ -z "${OSD_DEVICE}" ]];then
    log "ERROR- You must provide a device to build your OSD ie: /dev/sdb"
    exit 1
  fi

  if [[ ! -e "${OSD_DEVICE}" ]]; then
    log "ERROR- The device pointed by OSD_DEVICE ($OSD_DEVICE) doesn't exist !"
    exit 1
  fi

  # instead of starting the latest osd, let us instead specify exactly which osd to start
  #start_osd() {

  # from the pg, knowing the osd device, get the associate vg
  pg_to_vg=$(pvdisplay $OSD_DEVICE | grep "VG Name" | rev | cut -d " " -f 1 | rev)

  # this is using ceph-volume inventory
  # we can also use ceph-volume lvm list

  ceph_volume=$(ceph-volume inventory $OSD_DEVICE --format json)
  ceph_osd_id=$(echo $ceph_volume | jq '.["lvs"][0]."osd_id" | tonumber')
  ceph_osd_name=$(echo $ceph_volume | jq '.["lvs"][0]."name"')
  ceph_osd_block=$(echo $ceph_volume | jq '.["lvs"][0]."block_uuid"')

  OSD_ID=$ceph_osd_id
  osd_path=/var/lib/ceph/osd
  for osd in `ls $osd_path`; do
    if [[ -f "$osd_path/$osd/fsid" ]]; then
      log "checking $osd_path/$osd/fsid -> $(cat $osd_path/$osd/fsid)"
      if [[ "$(cat $osd_path/$osd/fsid)" == "$osd_block" ]]; then
        OSD_ID=$( echo $osd | rev | cut -d '-' -f 1 | rev)
      fi
    fi
  done

  if [[ -z "$OSD_ID" ]]; then
    log "Did not find OSD!"
    exit 1
  else
    log "osd id: $OSD_ID"
  fi

  log "SUCCESS"

  /usr/bin/ceph-osd "${CLI_OPTS[@]}" -f -i "${OSD_ID}" --cluster $CLUSTER --setuser ceph --setgroup disk
}

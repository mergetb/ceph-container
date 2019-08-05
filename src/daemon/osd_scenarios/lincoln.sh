#!/bin/bash
set -e

function osd_lvm_format {
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

    ceph-volume create --yes --bluestore "${OSD_DEVICE}" --no-systemd
}


# lots of assumptions
function osd_daemon {

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

  osd_fsid=$(pvdisplay  -c | grep $OSD_DEVICE | cut -d ':' -f 2)
  osd_block=$(ls /dev/$osd_fsid | cut -d '-' -f 3-)

  OSD_ID=""
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

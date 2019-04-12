#!/bin/bash
set -e

if is_redhat; then
  if [[ -n "${TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES}" ]]; then
    sed -i -e "s/^\(TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES\)=.*/\1=${TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES}/" /etc/sysconfig/ceph
  fi
  source /etc/sysconfig/ceph
fi

function start_osd {
  get_config
  check_config

  if [ "${CEPH_GET_ADMIN_KEY}" -eq 1 ]; then
    get_admin_key
    check_admin_key
  fi

  case "$OSD_TYPE" in
    directory)
      source /opt/ceph-container/bin/osd_directory.sh
      source /opt/ceph-container/bin/osd_common.sh
      osd_directory
      ;;
    directory_single)
      source /opt/ceph-container/bin/osd_directory_single.sh
      osd_directory_single
      ;;
    activate)
      source /opt/ceph-container/bin/osd_disk_activate.sh
      osd_activate
      ;;
    devices)
      source /opt/ceph-container/bin/osd_disks.sh
      source /opt/ceph-container/bin/osd_common.sh
      osd_disks
      ;;
    *)
      osd_trying_to_determine_scenario
      ;;
  esac
}

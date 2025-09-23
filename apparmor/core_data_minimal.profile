# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

#include <tunables/global>

profile core_data_minimal flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  #include <abstractions/openssl>
  #include <abstractions/bash>

  network inet,
  network inet6,

  capability chown,
  capability dac_override,
  capability dac_read_search,
  capability fowner,
  capability kill,
  capability net_bind_service,
  capability setgid,
  capability setuid,
  capability sys_resource,

  /bin/**              mrpx,
  /sbin/**             mrpx,
  /usr/**              mrpx,
  /lib/**              mrpx,
  /lib64/**            mrpx,
  /etc/**              r,
  /etc/ssl/**          r,
  /etc/pki/**          r,
  /etc/hosts           r,
  /etc/hostname        r,
  /etc/resolv.conf     r,

  /proc/**             r,
  deny /proc/*/fd/[0-9]*    rw,

  /sys/**              r,

  /dev/null            rw,
  /dev/urandom         r,
  /dev/random          r,
  /dev/zero            rw,

  /var/lib/**          rwk,
  /var/run/**          rwk,
  /var/log/**          rwk,
  /run/**              rwk,
  /tmp/**              rwk,
  /opt/**              rwk,
  /backups/**          rwk,
  /home/postgres/**    rwk,
  /run/secrets/**      r,

  deny /root/**        rwx,
  deny /home/**        rwx,
  deny /etc/shadow     r,
  deny /etc/gshadow    r,
  deny /etc/sudoers    r,
  deny /var/lib/docker/** rwx,
  deny /var/run/docker.sock rwx,

  ptrace (readby),
}

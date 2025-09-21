# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# pg_hba.conf template rendered during init

# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
host    all             all             ${DOCKER_NETWORK_SUBNET} scram-sha-256
host    replication     all             ${DOCKER_NETWORK_SUBNET} scram-sha-256

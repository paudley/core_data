

# **Production-Grade PostgreSQL 17 in Docker: A 2025 Guide to Security, Performance, and Robustness**

## **Introduction**

The practice of running stateful workloads such as relational databases within containers has undergone a significant transformation. Once considered an antipattern suitable only for development and testing, containerizing production databases is now a mainstream strategy, driven by the operational efficiencies of immutable infrastructure and declarative deployments.1 The official PostgreSQL Docker image, in particular, provides a robust foundation, but leveraging it for production-grade systems requires a disciplined, multi-faceted approach that extends far beyond a simple

docker run command.2

This report provides an exhaustive, forward-looking guide to deploying and managing PostgreSQL 17 in Docker for the year 2025 and beyond. It is structured around the three foundational pillars of a production-ready system: Security, Performance, and Robustness. These domains are not independent silos but are deeply interconnected; a security decision can have performance implications, and a performance tuning choice can affect robustness. Therefore, this guide advocates for a holistic, defense-in-depth methodology, where each layer of the stack—from the host kernel to the PostgreSQL configuration—is deliberately engineered for production demands.

The analysis will move beyond rudimentary best practices to explore advanced topics essential for a modern, secure, and resilient database architecture. This includes kernel-level sandboxing with seccomp and AppArmor, a nuanced approach to performance tuning that considers the entire I/O path, and architectural patterns for achieving high availability and automated recovery. Each section presents validated patterns to be implemented and common antipatterns to be avoided, substantiated with detailed explanations and actionable configuration examples to provide a comprehensive blueprint for the core\_data project and similar production deployments.

## **Advanced Security Hardening**

A secure PostgreSQL deployment in Docker is the result of a multi-layered strategy that applies the principle of least privilege at every level of the stack. This begins with restricting the container's runtime privileges, proceeds to kernel-level sandboxing to limit the container's interaction with the host, and extends to securing data in transit and at rest, isolating the network, and ensuring the integrity of the software supply chain.

### **The Principle of Least Privilege in the Container**

The fundamental goal of container security is to minimize the potential damage an attacker can inflict if they compromise a containerized application. Running a container with excessive privileges, particularly as the root user, creates a significant risk. A container escape vulnerability could allow an attacker to pivot from controlling the container to gaining unrestricted root access on the host machine, compromising the entire system.3 Therefore, every configuration choice must be aimed at reducing the container's capabilities to the absolute minimum required for it to function.

**Pattern: Run as a Dedicated Non-Root User**

While the official PostgreSQL image internally switches to the postgres user (UID 999\) to run the database process, the container's entrypoint script may initiate as root to perform setup tasks like changing file ownership.5 A more secure posture is to force the container to launch with a non-root user from the outset, which requires careful coordination between the host and the container.

This approach creates a direct dependency between the security context of the container and the filesystem permissions of the host volume. To implement this correctly, the host's orchestration layer must prepare the data directory *before* the container starts. The process is as follows:

1. Create a dedicated, unprivileged user on the host system.  
   Bash  
   sudo useradd \--system \--uid 2000 \--shell /bin/false postgres\_docker

2. Create the host directory for the PostgreSQL data volume and set its ownership to match the newly created user. Permissions should be restrictive.  
   Bash  
   sudo mkdir \-p /opt/core\_data/postgres-data  
   sudo chown 2000:2000 /opt/core\_data/postgres-data  
   sudo chmod 700 /opt/core\_data/postgres-data

3. Specify the non-root user in the docker-compose.yml file. This ensures the container process runs with the specified UID and GID, which now align with the host directory permissions.  
   YAML  
   \# docker-compose.yml  
   services:  
     db:  
       image: postgres:17-alpine  
       user: "2000:2000"  
       volumes:  
         \- /opt/core\_data/postgres-data:/var/lib/postgresql/data  
       \#... other configurations

This pattern moves the responsibility of directory ownership from the container's entrypoint script to the deployment automation, effectively removing the need for the container to have root-like privileges at startup.6

**Antipattern: Relying on the Image's Internal User Alone**

Simply trusting the image to drop privileges internally is insufficient. If the container starts as root, it retains those privileges during the initial execution of its entrypoint script. An exploit targeting this phase could be catastrophic. The goal is to enforce the principle of least privilege from the moment the container is instantiated.

**Pattern: Prevent Privilege Escalation**

To further harden the container, it is essential to prevent any process within it from gaining new privileges. The no-new-privileges security option blocks the effects of setuid or setgid bits on executables, which is a common vector for privilege escalation attacks.3

YAML

\# docker-compose.yml  
services:  
  db:  
    \#...  
    security\_opt:  
      \- no\-new-privileges:true

**Pattern: Drop All Unnecessary Capabilities**

Linux capabilities break down the monolithic power of the root user into distinct, granular privileges. By default, Docker grants a set of capabilities to containers. The most secure approach is to drop all default capabilities and then add back only those that are strictly necessary.3 For a PostgreSQL container that has its volume permissions managed externally as described above, it may require no special capabilities at all. If the entrypoint script must perform ownership changes,

CAP\_CHOWN might be required.

YAML

\# docker-compose.yml  
services:  
  db:  
    \#...  
    cap\_drop:  
      \- ALL  
    \# cap\_add:  
    \#   \- CHOWN  \# Only add if absolutely necessary for the entrypoint script

**Antipattern: Running with \--privileged**

The \--privileged flag is a dangerous setting that should never be used in production for a database container. It effectively disables all isolation mechanisms, including capabilities, AppArmor, and seccomp, giving the container nearly full access to the host's devices and kernel features.3

### **Kernel-Level Isolation with Linux Security Modules (LSM)**

Linux Security Modules (LSMs) like Seccomp and AppArmor provide a powerful, kernel-enforced second layer of defense. They operate independently of the container's user and capabilities, restricting what the container can do even if an attacker gains control of a process within it.

#### **Seccomp for System Call Filtering**

Secure Computing Mode (seccomp) acts as a firewall for system calls (syscalls), which are the interface through which user-space processes request services from the Linux kernel.7 By filtering which syscalls a container can make,

seccomp dramatically reduces the kernel's attack surface.

Docker applies a default seccomp profile that blocks approximately 44 of the 300+ available syscalls, including those related to module loading, clock manipulation, and kernel keyring access.7 While this default profile is a significant improvement over no filtering, a custom, whitelist-based profile tailored specifically to PostgreSQL offers the highest level of security.

**Pattern: Generate and Apply a Custom, Whitelist-Based Seccomp Profile**

Generating a custom profile is not a one-time action but a continuous lifecycle process. A profile created under limited test conditions may fail in production when an unusual code path or maintenance operation triggers a syscall that was not observed during generation.9 A robust operational workflow involves generating a baseline, refining it with real-world data, and then enforcing it.

1. **Generate a Baseline Profile:** Use strace to trace the syscalls made by the PostgreSQL container during a representative workload.  
   * Create a temporary Dockerfile to add the strace utility.  
     Dockerfile  
     FROM postgres:17\-alpine  
     RUN apk add \--no-cache strace  
     ENTRYPOINT \["strace", "-ff", "-o", "/var/lib/postgresql/data/strace.out", "/usr/local/bin/docker-entrypoint.sh"\]  
     CMD \["postgres"\]

   * Build and run this instrumented container, exercising all expected database operations: startup, client connections, various query types (SELECT, INSERT, UPDATE, DELETE), index creation, vacuuming, pg\_dump, and graceful shutdown. The \-ff flag is crucial as it traces all forked processes.9  
   * After the test run, stop the container. The strace.out.\* files in the data volume will contain a raw list of all syscalls used.  
2. **Create the JSON Profile:** Process the strace output to create a whitelist profile. Tools like seccomp-gen can automate this, or a custom script can be used to parse the syscall names and generate the required JSON structure.9 The profile must have a  
   defaultAction of SCMP\_ACT\_ERRNO, which denies any syscall not explicitly listed.11  
   JSON  
   {  
     "defaultAction": "SCMP\_ACT\_ERRNO",  
     "architectures":,  
     "syscalls":  
       },  
       {  
         "name": "epoll\_wait",  
         "action": "SCMP\_ACT\_ALLOW",  
         "args":  
       },  
       //... list of all other required syscalls  
     \]  
   }

3. **Test and Refine:** Apply the generated profile in a staging environment. It is common for the initial profile to be too restrictive. When the container fails with an "Operation not permitted" error, the kernel logs will indicate the blocked syscall. Add the missing syscall to the profile and repeat testing.  
4. **Deploy and Enforce:** Once the profile is stable in staging, apply it to the production container using the seccomp security option.  
   YAML  
   \# docker-compose.yml  
   services:  
     db:  
       \#...  
       security\_opt:  
         \- seccomp:/path/to/host/postgres-seccomp.json

**Antipattern: Running with seccomp=unconfined**

Disabling seccomp by setting it to unconfined should only be done for temporary debugging.8 In a production environment, this removes a critical security boundary and exposes the host kernel to unnecessary risk. Recent issues with newer base operating systems using syscalls unknown to older

libseccomp versions on the host have sometimes required this as a temporary workaround, but the proper solution is to update the host's libseccomp package.12

#### **AppArmor for Mandatory Access Control (MAC)**

AppArmor confines programs to a specific set of resources (e.g., file paths, network sockets, capabilities).13 Unlike

seccomp, which focuses on kernel interactions, AppArmor focuses on resource access. It is an excellent complementary technology for preventing a compromised process from reading sensitive files or making outbound network connections.

**Pattern: Develop a Custom AppArmor Profile**

Similar to seccomp, Docker's docker-default AppArmor profile is generic. A custom profile for PostgreSQL provides much stronger guarantees.13 The process involves creating a profile file, loading it into the kernel, and then applying it to the container.

1. **Create the Profile:** Create a file (e.g., /etc/apparmor.d/containers/docker-postgres) with rules tailored to PostgreSQL. The profile should deny by default and explicitly allow necessary actions.  
   \#include \<tunables/global\>

   profile docker-postgres flags=(attach\_disconnected,mediate\_deleted) {  
     \#include \<abstractions/base\>

     \# Deny all network access by default  
     deny network,  
     \# Allow TCP listen/accept on the Postgres port  
     network tcp listen,  
     network tcp accept,

     \# Allow essential capabilities  
     capability sys\_chroot,  
     capability setgid,  
     capability setuid,

     \# Deny write access to most of the filesystem  
     deny /\*\* w,

     \# Allow full access to the data directory  
     /var/lib/postgresql/data/ r,  
     /var/lib/postgresql/data/\*\* rw,

     \# Allow read access to config files  
     /etc/postgresql/\*\* r,  
     /usr/share/postgresql/\*\* r,

     \# Allow execution of postgres binaries  
     /usr/lib/postgresql/17/bin/\* ix,  
     /usr/local/bin/docker-entrypoint.sh ix,

     \# Deny execution of common shells and tools  
     deny /bin/bash x,  
     deny /bin/sh x,  
     deny /usr/bin/top x,  
   }

2. **Load the Profile:** Use apparmor\_parser to load the profile into the kernel. It is often useful to first load it in "complain mode" to audit for violations without blocking them, allowing for refinement based on real-world usage.14  
   Bash  
   \# Load in complain mode for testing  
   sudo apparmor\_parser \-C /etc/apparmor.d/containers/docker-postgres

   \# Load in enforce mode for production  
   sudo apparmor\_parser \-r \-W /etc/apparmor.d/containers/docker-postgres

3. **Apply the Profile:**  
   YAML  
   \# docker-compose.yml  
   services:  
     db:  
       \#...  
       security\_opt:  
         \- apparmor:docker-postgres

Tools like bane can help automate the generation of AppArmor profiles from a configuration file, providing a good starting point.14

**Antipattern: Disabling AppArmor**

Running with \--security-opt apparmor=unconfined removes this entire layer of MAC protection and should be avoided in production.17

### **Securing Data and Credentials**

Protecting sensitive information, such as database passwords and TLS keys, from accidental exposure is paramount.

**Pattern: Use Docker Secrets for All Sensitive Data**

Environment variables are a common but insecure method for passing secrets to containers. They can be easily viewed with docker inspect and are often leaked into logs or monitoring systems.18 Docker Secrets provide a much more secure mechanism by mounting sensitive data as in-memory files (

tmpfs) within the container, accessible only to services that have been explicitly granted permission.19

The official PostgreSQL image supports this pattern natively through the \_FILE suffix convention.

YAML

\# docker-compose.yml  
services:  
  db:  
    image: postgres:17-alpine  
    environment:  
      \# Point to the secret file instead of passing the password directly  
      POSTGRES\_PASSWORD\_FILE: /run/secrets/postgres\_password  
      POSTGRES\_USER: core\_user  
      POSTGRES\_DB: core\_data  
    secrets:  
      \- postgres\_password

secrets:  
  postgres\_password:  
    file:./path/to/host/postgres\_password.txt

In this configuration, Docker mounts the content of ./path/to/host/postgres\_password.txt to /run/secrets/postgres\_password inside the container. The PostgreSQL entrypoint script detects the \_FILE suffix and reads the password from this file instead of the environment variable.20

**Antipattern: Hardcoding Secrets in Images or Environment Variables**

Never place plaintext passwords or other secrets directly in a Dockerfile or in the environment section of a docker-compose.yml file. This is a severe security vulnerability that makes secrets easily discoverable.19

**Pattern: Enforce SSL/TLS for All Connections**

All network traffic between database clients and the PostgreSQL server must be encrypted to protect against eavesdropping and man-in-the-middle attacks.

1. **Generate Certificates:** Use OpenSSL or a trusted Certificate Authority (CA) to generate a CA certificate, a server certificate and key, and client certificates.5  
2. **Configure PostgreSQL:** Securely mount the server certificate and key into the container. Then, mount custom postgresql.conf and pg\_hba.conf files.  
   * In postgresql.conf, enable SSL and specify the paths to the certificate and key files mounted inside the container.5  
     Ini, TOML  
     \# postgresql.conf  
     ssl \= on  
     ssl\_cert\_file \= '/var/lib/postgresql/server.crt'  
     ssl\_key\_file \= '/var/lib/postgresql/server.key'

   * In pg\_hba.conf, change connection types from host to hostssl to reject any connection that is not encrypted with TLS.5  
     \# pg\_hba.conf  
     \# TYPE  DATABASE        USER            ADDRESS                 METHOD  
     \# Reject non-SSL connections from remote hosts  
     hostnossl all           all             0.0.0.0/0               reject  
     \# Require SSL for all remote connections  
     hostssl   all           all             0.0.0.0/0               scram-sha-256

### **Network Security and Isolation**

By default, Docker containers can communicate with each other over a default bridge network. A more secure configuration involves creating dedicated networks to isolate services and strictly controlling access to the database.

**Pattern: Isolate the Database in a Custom Bridge Network**

Custom Docker networks provide better isolation and an automatic DNS service that allows containers to resolve each other by their service name.18

YAML

\# docker-compose.yml  
services:  
  db:  
    image: postgres:17-alpine  
    networks:  
      \- db-net  
    \#...  
  app:  
    image: my-app:latest  
    networks:  
      \- db-net  
    environment:  
      \# The app can connect to the DB using the hostname 'db'  
      DATABASE\_HOST: db

networks:  
  db-net:  
    driver: bridge

**Pattern: Restrict listen\_addresses**

To prevent the database from being accidentally exposed, postgresql.conf should be configured to listen only on the container's internal network interface, not on all interfaces (\*). In a Docker Compose setup, this is typically the service name.18 However, since the internal IP can be dynamic, a common practice is to listen on

\* but rely on strict pg\_hba.conf and host firewall rules for protection. A more advanced setup could involve an entrypoint script that determines the container's IP and dynamically sets listen\_addresses.

**Pattern: Implement Strict pg\_hba.conf Rules**

The pg\_hba.conf file is the primary gatekeeper for PostgreSQL connections. It should be configured to only allow connections from the specific IP range of the custom Docker network.22 The subnet can be defined in the

docker-compose.yml file and referenced in a mounted pg\_hba.conf.

YAML

\# docker-compose.yml  
networks:  
  db-net:  
    driver: bridge  
    ipam:  
      config:  
        \- subnet: 172.20.0.0/24

\# pg\_hba.conf  
\# Allow connections only from other containers on the db-net network  
host    all             all             172.20.0.0/24           scram-sha-256

This configuration ensures that even if the PostgreSQL port were accidentally exposed on the host, only clients originating from within the 172.20.0.0/24 Docker network could attempt to authenticate.

**Antipattern: Exposing Port 5432 to the World**

Mapping the PostgreSQL port directly to the host (ports: \["5432:5432"\]) should be avoided unless external access is absolutely required. Even then, it must be protected by a host firewall that restricts access to trusted IP addresses.24 The preferred pattern is for application containers to connect to the database over the internal, isolated Docker network.

### **Image and Supply Chain Security**

The security of the running container depends entirely on the integrity of the image it is based on.

**Pattern: Pin to Specific Image Versions**

Always use a specific, immutable image tag (e.g., postgres:17.2-alpine) rather than a floating tag like latest or 17\.18 This practice guarantees reproducible builds and prevents unexpected updates from introducing vulnerabilities or breaking changes into the production environment.2

**Pattern: Use Minimal Base Images**

The Alpine-based variants of the PostgreSQL image (e.g., postgres:17-alpine) are significantly smaller and have a reduced attack surface. They include a minimal set of libraries and utilities, leaving less for an attacker to exploit if they gain access to the container.1

**Pattern: Regularly Scan Images for Vulnerabilities**

Integrate an image scanner such as Trivy, Grype, or Docker Scout into the CI/CD pipeline. These tools analyze image layers and identify known vulnerabilities (CVEs) in OS packages and application dependencies, allowing them to be patched before deployment.3

**Pattern: Use Signed and Verified Images**

Docker Content Trust (DCT) provides a mechanism to cryptographically sign and verify images. By enabling DCT, the Docker client will refuse to pull an image unless it has a valid signature, ensuring that the image has not been tampered with since it was pushed by its author.21

## **Performance Tuning and Optimization**

Achieving optimal performance for PostgreSQL in Docker requires a holistic approach that addresses resource allocation at the container level, the efficiency of the storage subsystem, and the fine-tuning of the PostgreSQL engine itself. While the overhead of containerization on a native Linux host is often negligible for CPU-bound tasks, the I/O path for a write-intensive database is a critical area for optimization and can be a significant performance bottleneck if misconfigured.25

### **Host and Container Resource Management**

Properly allocating host resources to the container is the first step in ensuring predictable and stable performance.

**Pattern: Set Explicit Memory and CPU Limits**

Unconstrained containers can consume all available host resources, leading to resource starvation for other processes and causing system instability. It is crucial to set explicit resource limits using Docker's runtime flags.18

* \--memory: Sets a hard limit on the amount of memory the container can use.  
* \--cpus: Constrains the number of CPU cores the container can utilize.

A sensible starting point for a moderately-sized database might be:

Bash

docker run... \--memory="4g" \--cpus="2.0"...

These limits prevent the "noisy neighbor" problem and allow for more predictable capacity planning.

**Pattern: Configure Shared Memory (--shm-size)**

PostgreSQL makes extensive use of shared memory (/dev/shm) for mechanisms like parallel query execution. Docker's default shared memory size is a restrictive 64MB, which is often insufficient for database workloads and can cause performance degradation or errors. It is essential to increase this limit. A common rule of thumb is to set \--shm-size to approximately 25% of the container's total memory limit.27

YAML

\# docker-compose.yml  
services:  
  db:  
    image: postgres:17-alpine  
    shm\_size: '1g' \# For a container with a 4g memory limit  
    \#...

**Antipattern: No Resource Limits**

Running a production database container without defined memory and CPU limits is a significant operational risk. A runaway query or memory leak could exhaust host resources, leading to a crash of the database, other containers, or the entire host system.

### **Storage and I/O Performance**

For a database, I/O performance is paramount. The way Docker manages storage can have a profound impact on database throughput and latency. The choice between volume types and the configuration of the underlying host storage are among the most critical performance decisions.

**Pattern: Use Docker Named Volumes on High-Performance Host Storage**

For the main PostgreSQL data directory (PGDATA), Docker named volumes are the strongly recommended pattern.1

* **Performance:** On Linux, named volumes are simply directories managed by Docker within /var/lib/docker/volumes/, and they provide near-native filesystem performance.25 On macOS and Windows, where Docker runs in a VM, named volumes still offer significantly better performance than bind mounts due to optimized I/O paths.29  
* **Management:** Named volumes are managed by the Docker lifecycle, making them easier to create, inspect, and back up.

To maximize performance, the host directory /var/lib/docker/ should be located on the fastest available storage, ideally a local NVMe SSD.30

YAML

\# docker-compose.yml  
services:  
  db:  
    image: postgres:17-alpine  
    volumes:  
      \# Use a named volume for the primary data directory  
      \- pgdata:/var/lib/postgresql/data  
    \#...

volumes:  
  pgdata:  
    driver: local

**Pattern: Use Separate Volumes for WAL and Data**

For extremely high-write workloads, separating the Write-Ahead Log (WAL) from the main data files onto different physical storage devices can improve performance. The WAL is written sequentially, while data files experience more random I/O. By placing them on separate devices, I/O contention can be reduced. This can be achieved using the POSTGRES\_INITDB\_WALDIR environment variable during the initial database setup.31

YAML

\# docker-compose.yml  
services:  
  db:  
    \#...  
    environment:  
      POSTGRES\_INITDB\_WALDIR: /var/lib/postgresql/wal  
    volumes:  
      \- pgdata:/var/lib/postgresql/data  
      \- pgwal:/var/lib/postgresql/wal

volumes:  
  pgdata:  
  pgwal:

This pattern assumes the pgwal volume can be mapped to a physically distinct, high-performance storage device on the host.

**Antipattern: Using Bind Mounts for PGDATA**

While convenient for development, using a bind mount (mounting a host path directly) for the PGDATA directory in production is an antipattern. It can introduce performance overhead, especially on non-Linux systems, and can create complex file permission issues between the host and the container.25

**Antipattern: Using Ephemeral Storage for Production**

Relying on the container's writable layer for data storage is a critical error. All data will be irretrievably lost when the container is removed.1 While

tmpfs mounts can be used for extremely fast, ephemeral test databases where durability is not a concern, they are entirely unsuitable for production data.32

### **PostgreSQL Configuration (postgresql.conf) Tuning for Containers**

Tuning postgresql.conf is essential for tailoring the database engine to the specific workload and the resource constraints of its containerized environment. Configuration can be applied either by mounting a complete postgresql.conf file or, more flexibly, by passing individual parameters as command-line arguments in the docker-compose.yml file, which keeps the tuning parameters visible and version-controlled.27

The following table provides guidance on tuning key parameters, with starting rules specifically adapted for a container where memory and CPU are explicitly limited.

| Parameter | Description | Container-Aware Starting Rule | References |
| :---- | :---- | :---- | :---- |
| shared\_buffers | Memory for caching data pages. The most important memory setting. | 25% of the container's \--memory limit. | 26 |
| effective\_cache\_size | Planner's estimate of memory available for disk caching (shared\_buffers \+ OS cache). | 75% of the container's \--memory limit. | 26 |
| work\_mem | Memory for sorting, hashing, and other per-operation tasks before spilling to disk. | (--memory / max\_connections) / 3\. Start low and increase based on log\_temp\_files. | 26 |
| maintenance\_work\_mem | Memory for maintenance tasks like VACUUM, CREATE INDEX. | 10% of the container's \--memory limit. | 26 |
| max\_wal\_size / min\_wal\_size | Controls the trigger for checkpoints. Larger values smooth out I/O spikes. | max\_wal\_size: 2GB, min\_wal\_size: 1GB. Adjust based on write load. | 27 |
| checkpoint\_completion\_target | Spreads checkpoint I/O over time to reduce performance impact. | 0.9 (spread over 90% of the time between checkpoints). | 26 |
| random\_page\_cost | Planner's estimate of the cost of a non-sequential disk fetch. | 1.1 for SSDs/NVMe (which are standard for database volumes). | 34 |
| effective\_io\_concurrency | Number of concurrent I/O operations the storage can handle. | 200+ for modern SSDs. | 34 |
| log\_min\_duration\_statement | Logs queries slower than the specified time. Essential for finding bottlenecks. | 500ms to start. Lower for more verbose logging. | 33 |

Example implementation in docker-compose.yml:

YAML

\# docker-compose.yml  
services:  
  db:  
    \#...  
    command:  
      \- "postgres"  
      \- "-c"  
      \- "shared\_buffers=1GB"  
      \- "-c"  
      \- "effective\_cache\_size=3GB"  
      \- "-c"  
      \- "work\_mem=16MB"  
      \- "-c"  
      \- "maintenance\_work\_mem=256MB"  
      \- "-c"  
      \- "random\_page\_cost=1.1"  
      \#... other parameters

### **Logging Strategy for Performance**

Container logging, if not managed correctly, can degrade application performance and lead to host instability. The choice of logging driver and delivery mode is a performance-tuning decision.

**Pattern: Use the local Logging Driver with Rotation**

The default json-file logging driver does not perform log rotation, creating a risk of unbounded log growth that can fill the host's disk.37 The

local driver is the recommended alternative as it uses a more efficient on-disk format and enables rotation by default.38 This should be configured as the default for the Docker daemon in

/etc/docker/daemon.json.

JSON

{  
  "log-driver": "local",  
  "log-opts": {  
    "max-size": "100m",  
    "max-file": "5",  
    "compress": "true"  
  }  
}

This configuration retains up to 500MB of logs per container (5 files of 100MB each), with older files being compressed.

**Pattern: Use Non-Blocking Mode for High-Throughput Systems**

Docker offers two log delivery modes:

* **Blocking (default):** The application waits for the logging driver to process each message. This guarantees delivery but can introduce latency if the driver is slow.38  
* **Non-blocking:** The application writes logs to an in-memory buffer and continues execution immediately. The driver consumes from this buffer asynchronously. This maximizes application performance but risks dropping logs if the buffer overflows.37

For a write-intensive database generating a high volume of logs, where application latency is paramount, switching to non-blocking mode can be beneficial. The risk of log loss can be mitigated by increasing the buffer size.39

YAML

\# docker-compose.yml  
services:  
  db:  
    \#...  
    logging:  
      driver: "local"  
      options:  
        mode: non-blocking  
        max-buffer-size: 4m

**Antipattern: Neglecting Log Management**

Leaving the default json-file driver without rotation is a common cause of production outages. Unmanaged logs will eventually consume all available disk space, causing the database and potentially the entire host to fail.37

## **Ensuring Robustness and High Availability**

Robustness in a containerized database system encompasses data integrity, reliable operational lifecycle, and the architectural capacity to withstand failures. This requires moving beyond a single container to a fully engineered system that includes automated recovery, health monitoring, and, for critical applications, a high-availability (HA) cluster architecture.

### **Data Integrity and Recovery**

A robust database is a recoverable one. The ephemeral nature of containers makes a disciplined and automated backup strategy non-negotiable.

**Pattern: Automated pg\_dump with a Sidecar Container**

The sidecar pattern is an elegant way to manage backups without polluting the primary database container with backup logic or tools. A separate, lightweight container runs alongside the database container, connecting over the shared Docker network to perform backups on a schedule.40

YAML

\# docker-compose.yml  
services:  
  db:  
    image: postgres:17-alpine  
    networks:  
      \- db-net  
    volumes:  
      \- pgdata:/var/lib/postgresql/data  
    environment:  
      \#... db credentials  
    
  backup:  
    image: musab520/pgbackup-sidecar:latest  
    restart: always  
    networks:  
      \- db-net  
    volumes:  
      \- /opt/core\_data/backups:/opt/dumps \# Mount host path for backups  
    environment:  
      POSTGRES\_HOST: db  
      POSTGRES\_USER: core\_user  
      POSTGRES\_PASSWORD\_FILE: /run/secrets/postgres\_password  
      CRON\_TIME: "0 2 \* \* \*" \# Daily at 2 AM  
    secrets:  
      \- postgres\_password

networks:  
  db-net:

volumes:  
  pgdata:

secrets:  
  postgres\_password:  
    file:./postgres\_password.txt

This setup automates daily logical backups using pg\_dump, storing them on a host volume that can be further backed up to remote storage.40

**Pattern: Filesystem-Level Volume Snapshots**

For very large databases or when near-instantaneous backup and restore capabilities are needed, filesystem-level snapshots provide a powerful alternative to logical dumps. If the host's /var/lib/docker/volumes directory resides on a filesystem that supports atomic snapshots (e.g., ZFS, LVM, or cloud provider block storage), a consistent physical backup can be created with minimal downtime.42 The procedure is:

1. Briefly stop the database container to ensure a quiescent state: docker-compose stop db.  
2. Take a snapshot of the underlying storage volume.  
3. Restart the database container: docker-compose start db.  
   The downtime is typically only a few seconds.

**Pattern: Combining Logical and Physical Backups**

The most robust strategy combines both methods. Use frequent filesystem snapshots (e.g., hourly) for rapid disaster recovery of the entire database state. Complement this with less frequent logical pg\_dump backups (e.g., daily) which provide portability, version compatibility, and protection against data corruption that might be replicated in a physical snapshot.43

**Antipattern: Manual, Infrequent Backups**

Manual backups are prone to human error and are easily forgotten. The backup process must be fully automated and regularly tested to be considered reliable.

**Antipattern: Storing Backups on the Same Volume**

Storing backups in the same physical location as the primary data provides no protection against storage media failure or host loss. Backups must be copied to a separate physical device, ideally in a different geographic location.42

### **Container Health and Lifecycle Management**

An orchestrator like Docker Compose or Swarm relies on accurate health signals to manage the container lifecycle, including initial startup, rolling updates, and restarts.

**Pattern: Implement a Multi-Stage Health Check**

A simple process check is insufficient to determine if a database is truly "healthy." A robust health check must validate multiple layers of functionality. The pg\_isready utility is a good first step, as it confirms the server is accepting connections, but it does not guarantee that it can execute queries or that a replica is up-to-date.44

A more advanced health check should be implemented as a script that performs a sequence of validations:

1. **Is the server accepting connections?** (pg\_isready)  
2. **Can a simple query be executed?** (psql \-c 'SELECT 1')  
3. **(For replicas) Is replication lag within an acceptable threshold?** (Query pg\_stat\_replication).

This provides a much more reliable signal of health. This signal becomes critically important when used with depends\_on: condition: service\_healthy in Docker Compose, as it prevents dependent application containers from starting and connecting to a database that is not yet fully operational, avoiding cascading startup failures.44

YAML

\# docker-compose.yml  
services:  
  db:  
    \#...  
    healthcheck:  
      test:  
      interval: 10s  
      timeout: 5s  
      retries: 5  
      start\_period: 30s  
    
  app:  
    \#...  
    depends\_on:  
      db:  
        condition: service\_healthy

**Pattern: Ensure Graceful Shutdown**

When a container is stopped via docker stop or docker-compose down, Docker sends a SIGTERM signal to the main process, allowing it a grace period to shut down cleanly before a forceful SIGKILL is sent.46 The official PostgreSQL image is designed to correctly handle this signal, performing a clean shutdown that flushes all data to disk.48

For large, heavily-loaded databases, the default 10-second timeout may be insufficient. A SIGKILL risks data corruption. It is crucial to configure a longer grace period to ensure the shutdown completes successfully.49

YAML

\# docker-compose.yml  
services:  
  db:  
    \#...  
    stop\_grace\_period: 1m

**Antipattern: Force-Killing Containers**

In a production environment, commands like docker kill or docker rm \-f should never be part of a standard operational procedure. They bypass the graceful shutdown process and are equivalent to pulling the power cord on a physical server, posing a high risk of data corruption.

### **Architecting for High Availability (HA)**

For applications requiring minimal downtime, a single-container deployment is insufficient. A high-availability architecture involves a cluster of database nodes with automated failover capabilities. While Docker itself does not provide database-specific HA, it serves as the platform on which HA solutions can be built. The choice of architecture depends on the required level of automation and the underlying container orchestrator.

The following table compares common HA architectures for PostgreSQL in a containerized environment.

| Architecture | Failover Method | Key Dependencies | Pros | Cons | References |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **Streaming Replication with Docker Swarm** | **Manual / Scripted.** Requires operator intervention or custom scripts to promote a replica. | Docker Swarm for scheduling, shared network, persistent volumes on each node. | Simple to understand, leverages native PostgreSQL features. | Failover is not automatic, high risk of human error, potential for split-brain. | 50 |
| **Patroni Cluster** | **Automatic.** Patroni agent on each node uses a DCS for leader election and failover orchestration. | Distributed Consensus Store (DCS) like etcd, Consul, or ZooKeeper. HAProxy for connection routing. | Fully automated failover, industry standard for HA Postgres, mature and reliable. | Adds operational complexity (managing etcd and HAProxy), more components to monitor. | 54 |
| **Kubernetes Operator (e.g., CloudNativePG, Crunchy PGO)** | **Automatic.** The Operator (a custom Kubernetes controller) monitors the cluster state via the K8s API and orchestrates failover. | A running Kubernetes cluster. | Deep integration with Kubernetes (uses CRDs, services, etc.), automates the entire lifecycle (provisioning, backups, upgrades, failover). | Locks the solution into the Kubernetes ecosystem; requires Kubernetes expertise. | 58 |

For a project using Docker Compose or Docker Swarm, the **Patroni Cluster** represents the gold standard for automated high availability. It provides a robust, battle-tested solution that automates leader election, failover, and cluster state management, turning a collection of independent PostgreSQL containers into a resilient, self-healing system.54 While it introduces additional components like

etcd and HAProxy, the operational reliability it provides is essential for any critical production database.

## **Conclusion**

Deploying a production-grade PostgreSQL 17 server in Docker is a sophisticated engineering task that demands a deliberate and holistic strategy. The analysis presented in this report demonstrates that achieving a secure, performant, and robust database system is not the result of a single tool or configuration but rather the careful integration of practices across multiple layers of the technology stack.

The key findings underscore a clear set of actionable recommendations. Security must be built from the ground up, starting with the principle of least privilege by running containers as non-root users, dropping all unnecessary capabilities, and preventing privilege escalation. This foundational layer must be reinforced with kernel-level sandboxing through custom-generated seccomp and AppArmor profiles, which drastically reduce the system's attack surface. Performance is fundamentally a function of I/O; the use of named Docker volumes on high-performance host storage is the single most critical performance decision, preceding any postgresql.conf tuning. Finally, robustness is an architectural property achieved through automated backups, multi-stage health checks that provide accurate readiness signals, and, for critical systems, a fully automated high-availability cluster managed by a tool like Patroni.

For the core\_data project, the recommended path forward is an incremental one. The initial deployment should focus on creating a hardened single-node instance that incorporates all the security and performance patterns detailed in this report. This includes a non-root user setup, custom LSM profiles, Docker Secrets for credential management, a properly configured named volume, and a container-aware postgresql.conf tuning strategy. Once this resilient foundation is in place, and as availability requirements dictate, the architecture can evolve to a multi-node, high-availability cluster using Patroni. This approach ensures that the database system is not merely running in a container but is a truly engineered, production-ready service. The future of running such stateful services at scale lies in the declarative configurations and automated lifecycle management that these patterns represent, providing the foundation for a reliable and secure data platform for 2025 and beyond.

#### **Works cited**

1. Using Docker with Postgres: Tutorial and Best Practices \- Earthly Blog, accessed September 21, 2025, [https://earthly.dev/blog/postgres-docker/](https://earthly.dev/blog/postgres-docker/)  
2. How to Use the Postgres Docker Official Image, accessed September 21, 2025, [https://www.docker.com/blog/how-to-use-the-postgres-docker-official-image/](https://www.docker.com/blog/how-to-use-the-postgres-docker-official-image/)  
3. Docker Security \- OWASP Cheat Sheet Series, accessed September 21, 2025, [https://cheatsheetseries.owasp.org/cheatsheets/Docker\_Security\_Cheat\_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)  
4. Why Running Containers as Root is a Bad Idea? | by Sadi Zane ..., accessed September 21, 2025, [https://medium.com/@sadi.zane/why-running-containers-as-root-is-a-bad-idea-28ee69175a11](https://medium.com/@sadi.zane/why-running-containers-as-root-is-a-bad-idea-28ee69175a11)  
5. Secure PostgreSQL in Docker: SSL, Certificates & Config Best Practices \- Simple Talk, accessed September 21, 2025, [https://www.red-gate.com/simple-talk/databases/postgresql/running-postgresql-in-docker-with-proper-ssl-and-configuration/](https://www.red-gate.com/simple-talk/databases/postgresql/running-postgresql-in-docker-with-proper-ssl-and-configuration/)  
6. Running postgres docker container as a custom user | by kiran ..., accessed September 21, 2025, [https://justlike.medium.com/running-postgres-docker-container-as-a-custom-user-a2e484b2ae22](https://justlike.medium.com/running-postgres-docker-container-as-a-custom-user-a2e484b2ae22)  
7. Seccomp security profiles for Docker, accessed September 21, 2025, [https://docs.docker.com/engine/security/seccomp/](https://docs.docker.com/engine/security/seccomp/)  
8. Hardening Docker Container Using Seccomp Security Profile \- Gcore, accessed September 21, 2025, [https://gcore.com/learning/hardening-docker-container](https://gcore.com/learning/hardening-docker-container)  
9. How to use the new Docker Seccomp profiles \- Ramblings from Jessie, accessed September 21, 2025, [https://blog.jessfraz.com/post/how-to-use-new-docker-seccomp-profiles/](https://blog.jessfraz.com/post/how-to-use-new-docker-seccomp-profiles/)  
10. blacktop/seccomp-gen: Docker Secure Computing Profile Generator \- GitHub, accessed September 21, 2025, [https://github.com/blacktop/seccomp-gen](https://github.com/blacktop/seccomp-gen)  
11. Security Lab: Seccomp \- Play with Docker Classroom, accessed September 21, 2025, [https://training.play-with-docker.com/security-seccomp/](https://training.play-with-docker.com/security-seccomp/)  
12. Docker image for Postgres 14 based on BookWarm is broken somehow \#1100 \- GitHub, accessed September 21, 2025, [https://github.com/docker-library/postgres/issues/1100](https://github.com/docker-library/postgres/issues/1100)  
13. AppArmor security profiles for Docker, accessed September 21, 2025, [https://docs.docker.com/engine/security/apparmor/](https://docs.docker.com/engine/security/apparmor/)  
14. AppArmor: add a new security layer in Docker \- Theodo Cloud, accessed September 21, 2025, [https://security.theodo.com/en/blog/security-docker-apparmor](https://security.theodo.com/en/blog/security-docker-apparmor)  
15. AppArmor security profiles for Docker, accessed September 21, 2025, [https://test-dockerrr.readthedocs.io/en/latest/security/apparmor/](https://test-dockerrr.readthedocs.io/en/latest/security/apparmor/)  
16. genuinetools/bane: Custom & better AppArmor profile generator for Docker containers. \- GitHub, accessed September 21, 2025, [https://github.com/genuinetools/bane](https://github.com/genuinetools/bane)  
17. Securing containers with AppArmor | Container-Optimized OS \- Google Cloud, accessed September 21, 2025, [https://cloud.google.com/container-optimized-os/docs/how-to/secure-apparmor](https://cloud.google.com/container-optimized-os/docs/how-to/secure-apparmor)  
18. Best Practices for Running PostgreSQL in Docker (With Examples) \- Sliplane, accessed September 21, 2025, [https://sliplane.io/blog/best-practices-for-postgres-in-docker](https://sliplane.io/blog/best-practices-for-postgres-in-docker)  
19. The Complete Guide to Docker Secrets \- Earthly Blog, accessed September 21, 2025, [https://earthly.dev/blog/docker-secrets/](https://earthly.dev/blog/docker-secrets/)  
20. Secrets in Compose | Docker Docs, accessed September 21, 2025, [https://docs.docker.com/compose/how-tos/use-secrets/](https://docs.docker.com/compose/how-tos/use-secrets/)  
21. Docker Security in 2025: Best Practices to Protect Your Containers From Cyberthreats, accessed September 21, 2025, [https://cloudnativenow.com/topics/cloudnativedevelopment/docker/docker-security-in-2025-best-practices-to-protect-your-containers-from-cyberthreats/](https://cloudnativenow.com/topics/cloudnativedevelopment/docker/docker-security-in-2025-best-practices-to-protect-your-containers-from-cyberthreats/)  
22. Docker Postgres pg\_hba.conf: securing your containerized ..., accessed September 21, 2025, [https://www.byteplus.com/en/topic/556440](https://www.byteplus.com/en/topic/556440)  
23. Comprehensive PostgreSQL Security Checklist & Tips | EDB, accessed September 21, 2025, [https://www.enterprisedb.com/blog/how-to-secure-postgresql-security-hardening-best-practices-checklist-tips-encryption-authentication-vulnerabilities](https://www.enterprisedb.com/blog/how-to-secure-postgresql-security-hardening-best-practices-checklist-tips-encryption-authentication-vulnerabilities)  
24. Connecting to Postgresql in a docker container from outside \- Stack Overflow, accessed September 21, 2025, [https://stackoverflow.com/questions/37694987/connecting-to-postgresql-in-a-docker-container-from-outside](https://stackoverflow.com/questions/37694987/connecting-to-postgresql-in-a-docker-container-from-outside)  
25. Postgres in Docker benchmark : r/docker \- Reddit, accessed September 21, 2025, [https://www.reddit.com/r/docker/comments/onaerl/postgres\_in\_docker\_benchmark/](https://www.reddit.com/r/docker/comments/onaerl/postgres_in_docker_benchmark/)  
26. Performance Tuning PostgreSQL Containers in a Docker ..., accessed September 21, 2025, [https://pankajconnect.medium.com/performance-tuning-postgresql-containers-in-a-docker-environment-89ca7090e072](https://pankajconnect.medium.com/performance-tuning-postgresql-containers-in-a-docker-environment-89ca7090e072)  
27. Docker compose file for PostgreSQL with tuning config example ..., accessed September 21, 2025, [https://gist.github.com/narate/a50467636d24c1aa963c07de79b2d747](https://gist.github.com/narate/a50467636d24c1aa963c07de79b2d747)  
28. PostgreSQL in Docker: A Step-by-Step Guide for Beginners | DataCamp, accessed September 21, 2025, [https://www.datacamp.com/tutorial/postgresql-docker](https://www.datacamp.com/tutorial/postgresql-docker)  
29. Is read/write performance better with docker volumes on windows ..., accessed September 21, 2025, [https://stackoverflow.com/questions/62493402/is-read-write-performance-better-with-docker-volumes-on-windows-inside-of-a-doc](https://stackoverflow.com/questions/62493402/is-read-write-performance-better-with-docker-volumes-on-windows-inside-of-a-doc)  
30. Storage drivers \- Docker Docs, accessed September 21, 2025, [https://docs.docker.com/engine/storage/drivers/](https://docs.docker.com/engine/storage/drivers/)  
31. postgres \- Official Image \- Docker Hub, accessed September 21, 2025, [https://hub.docker.com/\_/postgres](https://hub.docker.com/_/postgres)  
32. Optimize Postgres Containers for Testing \[RE\#15\] | Babak K. Shandiz's Blog, accessed September 21, 2025, [https://babakks.github.io/article/2024/01/26/re-015-optimize-postgres-containers-for-testing.html](https://babakks.github.io/article/2024/01/26/re-015-optimize-postgres-containers-for-testing.html)  
33. How to change postgresql.conf in docker container? \- BytePlus, accessed September 21, 2025, [https://www.byteplus.com/en/topic/556425](https://www.byteplus.com/en/topic/556425)  
34. PostgreSQL Performance Tuning Settings \- Vlad Mihalcea, accessed September 21, 2025, [https://vladmihalcea.com/postgresql-performance-tuning-settings/](https://vladmihalcea.com/postgresql-performance-tuning-settings/)  
35. Run Docker postgres image with custom postgresql.conf \- CircleCI Discuss, accessed September 21, 2025, [https://discuss.circleci.com/t/run-docker-postgres-image-with-custom-postgresql-conf/51797](https://discuss.circleci.com/t/run-docker-postgres-image-with-custom-postgresql-conf/51797)  
36. Tuning PostgreSQL performance \[most important settings\] \- Bun, accessed September 21, 2025, [https://bun.uptrace.dev/postgres/performance-tuning.html](https://bun.uptrace.dev/postgres/performance-tuning.html)  
37. Configure logging drivers \- Docker Docs, accessed September 21, 2025, [https://docs.docker.com/engine/logging/configure/](https://docs.docker.com/engine/logging/configure/)  
38. Logging in Docker: Strategies and Best Practices | Better Stack ..., accessed September 21, 2025, [https://betterstack.com/community/guides/logging/how-to-start-logging-with-docker/](https://betterstack.com/community/guides/logging/how-to-start-logging-with-docker/)  
39. Docker logging best practices | Datadog, accessed September 21, 2025, [https://www.datadoghq.com/blog/docker-logging/](https://www.datadoghq.com/blog/docker-logging/)  
40. Musab520/pgbackup-sidecar \- GitHub, accessed September 21, 2025, [https://github.com/Musab520/pgbackup-sidecar](https://github.com/Musab520/pgbackup-sidecar)  
41. Backup/restore postgres in docker container · GitHub, accessed September 21, 2025, [https://gist.github.com/gilyes/525cc0f471aafae18c3857c27519fc4b](https://gist.github.com/gilyes/525cc0f471aafae18c3857c27519fc4b)  
42. Is there a way to backup and restore Docker Containers and Volumes? \- Reddit, accessed September 21, 2025, [https://www.reddit.com/r/selfhosted/comments/1hr4v3g/is\_there\_a\_way\_to\_backup\_and\_restore\_docker/](https://www.reddit.com/r/selfhosted/comments/1hr4v3g/is_there_a_way_to_backup_and_restore_docker/)  
43. Back Up and Share Docker Volumes with This Extension, accessed September 21, 2025, [https://www.docker.com/blog/back-up-and-share-docker-volumes-with-this-extension/](https://www.docker.com/blog/back-up-and-share-docker-volumes-with-this-extension/)  
44. Docker Compose Health Checks: An Easy-to-follow Guide | Last9, accessed September 21, 2025, [https://last9.io/blog/docker-compose-health-checks/](https://last9.io/blog/docker-compose-health-checks/)  
45. peter-evans/docker-compose-healthcheck: How to wait for ... \- GitHub, accessed September 21, 2025, [https://github.com/peter-evans/docker-compose-healthcheck](https://github.com/peter-evans/docker-compose-healthcheck)  
46. How to ensure proper shutdown of a Docker container | LabEx, accessed September 21, 2025, [https://labex.io/tutorials/docker-how-to-ensure-proper-shutdown-of-a-docker-container-415173](https://labex.io/tutorials/docker-how-to-ensure-proper-shutdown-of-a-docker-container-415173)  
47. How to gracefully shut down a long-running Docker container \- LabEx, accessed September 21, 2025, [https://labex.io/tutorials/docker-how-to-gracefully-shut-down-a-long-running-docker-container-417742](https://labex.io/tutorials/docker-how-to-gracefully-shut-down-a-long-running-docker-container-417742)  
48. How to safely stop/start my postgres server when using docker-compose \- Stack Overflow, accessed September 21, 2025, [https://stackoverflow.com/questions/52579820/how-to-safely-stop-start-my-postgres-server-when-using-docker-compose](https://stackoverflow.com/questions/52579820/how-to-safely-stop-start-my-postgres-server-when-using-docker-compose)  
49. how to safely restart postgresql container in kubernetes? \- Stack ..., accessed September 21, 2025, [https://stackoverflow.com/questions/75828221/how-to-safely-restart-postgresql-container-in-kubernetes](https://stackoverflow.com/questions/75828221/how-to-safely-restart-postgresql-container-in-kubernetes)  
50. Achieving High Availability with Docker Swarm, PostgreSQL and Django \- Opticore IT, accessed September 21, 2025, [https://www.opticoreit.com/data-centre-networks-blog/achieving-high-availability-with-docker-swarm-postgresql-and-django/](https://www.opticoreit.com/data-centre-networks-blog/achieving-high-availability-with-docker-swarm-postgresql-and-django/)  
51. An Easy Recipe for Creating a PostgreSQL Cluster with Docker Swarm | Crunchy Data Blog, accessed September 21, 2025, [https://www.crunchydata.com/blog/an-easy-recipe-for-creating-a-postgresql-cluster-with-docker-swarm](https://www.crunchydata.com/blog/an-easy-recipe-for-creating-a-postgresql-cluster-with-docker-swarm)  
52. High Availability in PostgreSQL: Replication with Docker \- Vuyisile Ndlovu, accessed September 21, 2025, [https://vuyisile.com/high-availability-in-postgresql-replication-with-docker/](https://vuyisile.com/high-availability-in-postgresql-replication-with-docker/)  
53. Running Rails \+ PostgreSQL in Docker Swarm cluster | by Vignesh \- Medium, accessed September 21, 2025, [https://medium.com/@svignesh/running-rails-postgresql-in-docker-swarm-cluster-431c0833d56e](https://medium.com/@svignesh/running-rails-postgresql-in-docker-swarm-cluster-431c0833d56e)  
54. Step-by-Step Guide: Configuring PostgreSQL HA with Patroni \- bootvar, accessed September 21, 2025, [https://bootvar.com/how-to-configure-postgresql-ha-with-patroni/](https://bootvar.com/how-to-configure-postgresql-ha-with-patroni/)  
55. High Availability PostgreSQL with Patroni \- OpenText Documentation Portal, accessed September 21, 2025, [https://docs.microfocus.com/doc/hcmx/24.1/hasqlpatroni](https://docs.microfocus.com/doc/hcmx/24.1/hasqlpatroni)  
56. Set Up High Availability PostgreSQL Cluster Using Patroni on ServerStadium, accessed September 21, 2025, [https://serverstadium.com/knowledge-base/set-up-high-availability-postgresql-cluster-using-patroni-on-serverstadium/](https://serverstadium.com/knowledge-base/set-up-high-availability-postgresql-cluster-using-patroni-on-serverstadium/)  
57. SETTING UP A POSTGRESQL HA CLUSTER | by Murat Bilal \- Medium, accessed September 21, 2025, [https://medium.com/@murat.bilal/setting-up-a-postgresql-ha-cluster-0a4348fca444](https://medium.com/@murat.bilal/setting-up-a-postgresql-ha-cluster-0a4348fca444)  
58. CloudNativePG \- PostgreSQL Operator for Kubernetes, accessed September 21, 2025, [https://cloudnative-pg.io/](https://cloudnative-pg.io/)  
59. High Availability \- Crunchy Data Customer Portal, accessed September 21, 2025, [https://access.crunchydata.com/documentation/postgres-operator/latest/architecture/high-availability](https://access.crunchydata.com/documentation/postgres-operator/latest/architecture/high-availability)  
60. Choosing a Kubernetes Operator for PostgreSQL \- Portworx, accessed September 21, 2025, [https://portworx.com/blog/choosing-a-kubernetes-operator-for-postgresql/](https://portworx.com/blog/choosing-a-kubernetes-operator-for-postgresql/)
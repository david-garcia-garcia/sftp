ARG DEBIAN_VERSION=12
FROM debian:${DEBIAN_VERSION}

# Steps done in one RUN layer:
# - Install upgrades and new packages
# - OpenSSH needs /var/run/sshd to run
# - Remove generic host keys, entrypoint generates unique keys
RUN apt-get update && \
    apt-get upgrade -y && \
    DEBIAN_FRONTEND="noninteractive" apt-get -y install --no-install-recommends openssh-server gettext-base && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /var/run/sshd && \
    rm -f /etc/ssh/ssh_host_*key*

COPY files/sshd_config.template /etc/ssh/sshd_config.template
COPY files/create-sftp-user /usr/local/bin/
COPY files/entrypoint /

RUN chmod +x /entrypoint /usr/local/bin/create-sftp-user

EXPOSE 22

ENTRYPOINT ["/entrypoint"]

# Container image that runs your code
FROM centos:centos7

# Copies your code file from your action repository to the filesystem path `/` of the container
COPY entry.sh /entry.sh
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
RUN install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
RUN curl -fsSl https://kubevela.net/script/install.sh | bash
RUN yum install epel-release -y
RUN yum install gettext -y
RUN yum install jq -y
RUN yum install wget -y

# Code file to execute when the docker container starts up (`entry.sh`)
ENTRYPOINT ["/entry.sh"]
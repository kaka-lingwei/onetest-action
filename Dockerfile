# Container image that runs your code
FROM alpine/k8s:1.23.13

# Copies your code file from your action repository to the filesystem path `/` of the container
COPY entrypoint.sh /entrypoint.sh
RUN curl -fsSl https://kubevela.net/script/install.sh | bash
RUN apk add util-linux

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/entrypoint.sh"]
FROM mcr.microsoft.com/azure-cli:latest

# Install Terraform
ARG TERRAFORM_VERSION=1.9.0
RUN apk add --no-cache wget unzip && \
    cd /tmp && \
    wget https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
    unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
    mv terraform /usr/local/bin/ && \
    chmod +x /usr/local/bin/terraform && \
    rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
    apk del wget unzip

# Verify installations
RUN terraform --version && \
    az --version

# Create working directory
WORKDIR /mnt/environments

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--help"]

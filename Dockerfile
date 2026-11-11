# syntax=docker/dockerfile:1.7
# =============================================================================
# qse-scanner - IBM Quantum Safe Explorer scan image for GitHub Actions
#
# Toolchains for every language QSE scans: Java (Maven/Gradle), Go, Python,
# C/C++, C#/.NET, Dart.
#
# Build (the QSE CLI repo is private; the token is a BuildKit secret and is
# never stored in any image layer or build history):
#   export QSE_TOKEN=<github.ibm.com token>
#   docker buildx build --secret id=qse_token,env=QSE_TOKEN -t qse-scanner:dev .
#
# Changes:
#   2026-08-21 - Initial creation (K8s/OpenShift CronJob image)
#   2026-11-11 - Reworked for GitHub Actions: BuildKit secret, full SDKs,
#                pinned toolchains, runs as root, qse-scan entrypoint
# =============================================================================

ARG UBI_IMAGE=registry.access.redhat.com/ubi9/ubi:latest

# -----------------------------------------------------------------------------
# Stage 1: fetch the QSE CLI (token only lives in this stage, as a secret mount)
# -----------------------------------------------------------------------------
FROM ${UBI_IMAGE} AS qse

ARG QSE_REPO_URL=https://github.ibm.com/quantum-safe-engineering/quantum-safe-read-repos.git
ARG QSE_REPO_REF=

RUN dnf install -y --setopt=install_weak_deps=False git \
    && dnf clean all && rm -rf /var/cache/dnf

RUN --mount=type=secret,id=qse_token,required=true \
    set -eu; \
    token="$(cat /run/secrets/qse_token)"; \
    auth_url="$(echo "${QSE_REPO_URL}" | sed "s|https://|https://${token}@|")"; \
    git clone --depth=1 ${QSE_REPO_REF:+--branch "${QSE_REPO_REF}"} "${auth_url}" /tmp/qse-repo; \
    mkdir -p /opt/qse; \
    cp -r /tmp/qse-repo/CLI/. /opt/qse/; \
    chmod +x /opt/qse/*.sh; \
    rm -rf /tmp/qse-repo

# -----------------------------------------------------------------------------
# Stage 2: scanner image
# -----------------------------------------------------------------------------
FROM ${UBI_IMAGE}

ARG TARGETARCH=amd64
ARG GO_VERSION=1.23.4
ARG MAVEN_VERSION=3.9.9
ARG GRADLE_VERSION=8.10.2
ARG DART_VERSION=3.5.4

LABEL org.opencontainers.image.title="qse-scanner" \
      org.opencontainers.image.description="IBM Quantum Safe Explorer scanner for GitHub Actions" \
      org.opencontainers.image.source="https://github.com/ncee-dp-tech-sme/qse_pod"

# ---- OS packages: full SDKs (javac, dotnet build, python headers) -----------
# curl-minimal is preinstalled in UBI9 (installing "curl" conflicts with it).
RUN dnf install -y --setopt=install_weak_deps=False \
        git jq findutils file unzip tar gzip which diffutils \
        java-17-openjdk-devel \
        python3 python3-pip python3-devel \
        gcc gcc-c++ make cmake \
        dotnet-sdk-8.0 \
    && dnf clean all && rm -rf /var/cache/dnf

# ---- Go ----------------------------------------------------------------------
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm /tmp/go.tgz

# ---- Maven -------------------------------------------------------------------
RUN curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o /tmp/maven.tgz \
    && tar -C /opt -xzf /tmp/maven.tgz \
    && ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn \
    && rm /tmp/maven.tgz

# ---- Gradle ------------------------------------------------------------------
RUN curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o /tmp/gradle.zip \
    && unzip -q /tmp/gradle.zip -d /opt \
    && ln -s "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle \
    && rm /tmp/gradle.zip

# ---- Dart SDK ----------------------------------------------------------------
RUN dart_arch="$([ "${TARGETARCH}" = "arm64" ] && echo arm64 || echo x64)" \
    && curl -fsSL "https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/dartsdk-linux-${dart_arch}-release.zip" -o /tmp/dart.zip \
    && unzip -q /tmp/dart.zip -d /opt \
    && rm /tmp/dart.zip

# ---- QSE CLI + scan entrypoint -----------------------------------------------
COPY --from=qse /opt/qse /opt/qse
COPY --chmod=0755 scripts/qse-scan.sh /usr/local/bin/qse-scan

# The Actions workspace is owned by the runner UID, not root
RUN git config --system --add safe.directory '*'

ENV QSE_HOME=/opt/qse \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk \
    GOROOT=/usr/local/go \
    GOPATH=/root/go \
    GOFLAGS=-buildvcs=false \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PATH="/opt/qse:/usr/local/go/bin:/root/go/bin:/opt/dart-sdk/bin:${PATH}"

# Runs as root on purpose: GitHub Actions job containers and `docker run`
# with a mounted workspace need write access to the checkout.
WORKDIR /github/workspace

ENTRYPOINT ["qse-scan"]

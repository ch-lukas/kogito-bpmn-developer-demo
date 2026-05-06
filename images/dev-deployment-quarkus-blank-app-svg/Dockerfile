# Layered fork of Apache KIE Sandbox's Dev Deployments base image,
# adding the kie-addons-quarkus-process-svg add-on so the runtime
# exposes /svg/processes/<id> and /svg/processes/<id>/instances/<iid>.
# Mgmt Console can then render the diagram pane (with live token) for
# any BPMN deployed via the Sandbox — same UX the local approval
# process gives today.
#
# Build:
#   docker build -t apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0-svg .
# Load into kind:
#   kind load docker-image apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0-svg --name kie-sandbox-dev-cluster
# Tell Sandbox to use it: set
#   KIE_SANDBOX_DEV_DEPLOYMENT_QUARKUS_BLANK_APP_IMAGE_URL=apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0-svg
# on the kogito-bpmn-editor container.
#
# Why we have to pre-stage the JARs:
# the upstream image runs Maven in *offline mode* against a private
# mirror (http://172.18.0.2/) hosted by the dev-deployment-base image,
# which doesn't ship process-svg. We work around it by writing the
# missing artifacts directly into the local m2 repo at
# /tmp/kogito/.m2/repository/ — Maven's local cache always wins over
# remote mirrors, so the offline build finds them.

FROM apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0

USER root

# 1) Patch pom.xml: add kie-addons-quarkus-process-svg before the top-level
#    </dependencies>. Indent-anchored so the </dependencies> tags inside
#    <build><plugins> don't match.
RUN sed -i 's|^  </dependencies>$|    <!-- Added by kogito-bpmn-analyst-demo: enables /svg/processes/<id> -->\n    <dependency>\n      <groupId>org.kie</groupId>\n      <artifactId>kie-addons-quarkus-process-svg</artifactId>\n    </dependency>\n  </dependencies>|' /home/app/pom.xml \
    && grep -A1 'kie-addons-quarkus-process-svg' /home/app/pom.xml

# 2) Pre-stage process-svg artifacts into the offline-mode local Maven
#    repo. Pulled from Maven Central at build time (when we have
#    internet); the runtime never needs to reach Central.
ARG MVN_CENTRAL=https://repo1.maven.org/maven2
ARG SVG_VERSION=10.1.0
RUN set -e; \
    REPO=/tmp/kogito/.m2/repository/org/kie; \
    for spec in \
        kie-addons-quarkus-process-svg:jar \
        kie-addons-quarkus-process-svg:pom \
        kie-addons-quarkus-process-svg-deployment:jar \
        kie-addons-quarkus-process-svg-deployment:pom \
        kie-addons-quarkus-process-svg-parent:pom \
        kie-addons-process-svg:jar \
        kie-addons-process-svg:pom; do \
      artifact="${spec%:*}"; ext="${spec#*:}"; \
      dir="$REPO/$artifact/$SVG_VERSION"; \
      mkdir -p "$dir"; \
      curl -fsSL -o "$dir/$artifact-$SVG_VERSION.$ext" \
        "$MVN_CENTRAL/org/kie/$artifact/$SVG_VERSION/$artifact-$SVG_VERSION.$ext"; \
    done; \
    echo "Staged process-svg artifacts:" && \
    ls -1 "$REPO"/kie-addons-quarkus-process-svg*/$SVG_VERSION/ \
          "$REPO"/kie-addons-process-svg/$SVG_VERSION/

# 3) The image's default user owns /tmp/kogito; restore ownership so
#    mvn at runtime doesn't trip on permissions.
RUN chown -R 1000:0 /tmp/kogito/.m2 || true

USER 1000

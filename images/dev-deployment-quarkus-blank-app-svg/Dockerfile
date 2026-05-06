# Layered fork of Apache KIE Sandbox's Dev Deployments base image,
# adding the kie-addons-quarkus-process-svg add-on so the runtime
# exposes /svg/processes/<id> and /svg/processes/<id>/instances/<iid>.
# Mgmt Console can then render the diagram pane (with live token) for
# any BPMN deployed via the Sandbox — same UX as the local approval
# process gives today.
#
# Build:
#   docker build -t apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0-svg .
# Load into kind:
#   kind load docker-image apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0-svg --name kie-sandbox-dev-cluster
# Tell Sandbox to use it: set
#   KIE_SANDBOX_DEV_DEPLOYMENT_QUARKUS_BLANK_APP_IMAGE_URL=apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0-svg
# on the kogito-bpmn-editor container.

FROM apache/incubator-kie-sandbox-dev-deployment-quarkus-blank-app:10.1.0

# Insert kie-addons-quarkus-process-svg as a new <dependency> immediately
# before the top-level </dependencies> (anchored to its 2-space indent so
# we don't touch the </dependencies> tags inside <build><plugins>).
USER root
RUN sed -i 's|^  </dependencies>$|    <!-- Added by kogito-bpmn-analyst-demo: enables /svg/processes/<id> -->\n    <dependency>\n      <groupId>org.kie</groupId>\n      <artifactId>kie-addons-quarkus-process-svg</artifactId>\n    </dependency>\n  </dependencies>|' /home/app/pom.xml \
    && grep -A1 'kie-addons-quarkus-process-svg' /home/app/pom.xml

# (Maven cache pre-warm intentionally omitted — the upstream image
# references a Jenkins-only kie-settings.xml at build time which can't be
# reproduced locally. The dep resolves on first deploy instead, ~5-10s.)

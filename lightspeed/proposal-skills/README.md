# OpenTelemetry Proposals skills

This directory contains observability skills for the OpenShift LightSpeed agentic operator. Each skill is a `SKILL.md` file (with optional helper scripts) that guides the agent through analysis, execution, and verification phases.

## Build and push

```bash
cd lightspeed/proposal-skills
podman build -t ghcr.io/pavolloffay/observability-agentic-skills:latest -f Containerfile .
podman push ghcr.io/pavolloffay/observability-agentic-skills:latest
```

The image is built `FROM scratch` — it contains only the skill files, no runtime. The agentic operator mounts it as a Kubernetes image volume into the agent's sandbox pod.

## Skills

### [missing-instrumentation-detector](missing-instrumentation-detector/SKILL.md)

Find deployments in a namespace that are not producing distributed traces,
detect the programming language, apply OpenTelemetry auto-instrumentation
via the `Instrumentation` CR + pod annotations, and verify traces flow.

**Lifecycle:** Analysis → Execution → Verification

**Prerequisites:**
- Red Hat build of OpenTelemetry operator installed
- An `OpenTelemetryCollector` instance with an OTLP receiver and traces pipeline
- Tempo (recommended) for trace storage and querying

**Example:**
```bash
oc apply -f missing-instrumentation-detector/example-proposal.yaml
```

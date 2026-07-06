---
name: missing-instrumentation-detector
description: Detect deployments in a namespace that are not producing distributed traces and recommend OpenTelemetry auto-instrumentation. Use when a user wants to find uninstrumented workloads, improve observability coverage, or enable tracing for applications.
---

# Missing Instrumentation Detector

## Purpose

Identify deployments in a target namespace that are not producing distributed
traces and recommend OpenTelemetry auto-instrumentation to close the gap.

The skill operates in three phases:

1. **Discovery** — list deployments and check for existing instrumentation
2. **Analysis** — classify each deployment and produce recommendations
3. **Execution** — apply OpenTelemetry `Instrumentation` CR and annotate workloads
4. **Verification** — confirm traces are flowing after instrumentation

## Inputs

The proposal request specifies:
- One or more target namespaces to scan
- Optionally, an `Instrumentation` CR manifest to apply (if not provided, one
  will be created using the discovered collector endpoint)
- Optionally, a specific deployment name to focus on

## Analysis Phase

### 1. Discover deployments

List all Deployments (and optionally StatefulSets, DaemonSets) in the target
namespace(s):

```bash
oc get deployments -n <namespace> -o json
```

For each deployment, record:
- Name, replicas, container images
- Whether pods are running and ready

Skip deployments with zero ready replicas — they cannot produce traces.

### 2. Check for existing instrumentation

For each deployment, check these indicators of existing tracing instrumentation:

**a) OpenTelemetry auto-instrumentation annotations:**

```bash
oc get deployment <name> -n <namespace> -o jsonpath='{.spec.template.metadata.annotations}' | grep -i 'instrumentation.opentelemetry.io'
```

The OpenTelemetry operator uses these annotations to inject auto-instrumentation:
- `instrumentation.opentelemetry.io/inject-java: "true"` or `"<Instrumentation-CR-name>"`
- `instrumentation.opentelemetry.io/inject-python: "true"` or `"<Instrumentation-CR-name>"`
- `instrumentation.opentelemetry.io/inject-nodejs: "true"` or `"<Instrumentation-CR-name>"`
- `instrumentation.opentelemetry.io/inject-dotnet: "true"` or `"<Instrumentation-CR-name>"`
- `instrumentation.opentelemetry.io/inject-go: "true"` or `"<Instrumentation-CR-name>"`
- `instrumentation.opentelemetry.io/inject-sdk: "true"` or `"<Instrumentation-CR-name>"`

**b) OpenTelemetry environment variables in containers:**

```bash
oc get deployment <name> -n <namespace> -o json | jq '.spec.template.spec.containers[].env[]? | select(.name | startswith("OTEL_"))'
```

Key variables: `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`,
`OTEL_TRACES_EXPORTER`, `OTEL_SDK_DISABLED`.

**c) Init containers injected by the OTel operator:**

```bash
oc get deployment <name> -n <namespace> -o json | jq '.spec.template.spec.initContainers[]? | select(.name | startswith("opentelemetry-auto-instrumentation"))'
```

**d) Existing Instrumentation CRs in the namespace:**

```bash
oc get instrumentations.opentelemetry.io -n <namespace> -o json
```

### 3. Detect the programming language

To recommend the correct auto-instrumentation type, detect the language using
the following methods **in order**. Stop at the first method that gives a clear
result.

#### Method 1: Image name heuristics (fast, no exec required)

If the language is not properly identified use Method 2: Process inspection below.

| Image pattern | Language |
|---|---|
| Contains `java`, `jdk`, `jre`, `maven`, `gradle`, `quarkus`, `spring`, `wildfly`, `tomcat`, `jboss`, `openjdk` | Java |
| Contains `python`, `django`, `flask`, `fastapi`, `gunicorn`, `uvicorn` | Python |
| Contains `node`, `npm`, `yarn`, `express`, `nextjs`, `nestjs` | Node.js |
| Contains `dotnet`, `aspnet`, `csharp` | .NET |
| Contains `golang`, `go` (as standalone segment) | Go |

#### Method 2: Process inspection (requires running pod)

If the image name is generic, inspect the main process (PID 1) in a running pod:

```bash
oc exec <pod> -n <namespace> -- cat /proc/1/cmdline | tr '\0' ' '
```

| Process pattern | Language |
|---|---|
| `java`, `java -jar`, `/usr/bin/java` | Java |
| `python`, `python3`, `gunicorn`, `uvicorn`, `flask` | Python |
| `node`, `npm`, `next`, `nest` | Node.js |
| `dotnet`, `/usr/bin/dotnet` | .NET |

For Go binaries (statically compiled, no recognizable runtime name), check for
the Go-specific ELF section:

```bash
oc exec <pod> -n <namespace> -- readelf -S /proc/1/exe 2>/dev/null | grep -q '.gopclntab' && echo "Go"
```

#### Method 3: Loaded shared libraries (works in distroless images)

If the container has no shell or `cat` is unavailable, inspect loaded libraries
from the node:

```bash
oc exec <pod> -n <namespace> -- cat /proc/1/maps 2>/dev/null | grep -oE 'libjvm|libpython|libnode|libcoreclr' | head -1
```

| Library | Language |
|---|---|
| `libjvm` | Java |
| `libpython` | Python |
| `libnode` | Node.js |
| `libcoreclr` | .NET |

#### Fallback

If none of the above methods determine the language, **do not stop or report
failure**. Use `inject-java` as the default — most enterprise workloads are
Java-based. If that is not appropriate, use `inject-sdk` which works for any
language that uses the OpenTelemetry SDK. The agent must always proceed with
instrumentation even when the language is uncertain.

### 4. Check prerequisites

Before recommending instrumentation, verify:

**a) The Red Hat build of OpenTelemetry operator is installed:**

```bash
oc get csv -A | grep opentelemetry
```

If not installed, flag as a blocker.

**b) An OpenTelemetryCollector instance exists and is receiving traces:**

```bash
oc get opentelemetrycollectors -A -o json
```

Check that at least one collector has an OTLP receiver and a traces pipeline.
If no collector exists, flag as a blocker and recommend deploying one first.

**c) A trace backend (Tempo) is deployed and reachable:**

```bash
oc get tempostacks -A -o json 2>/dev/null || oc get tempomonolithics -A -o json 2>/dev/null
```

If no Tempo instance exists, flag as a warning — traces can still be collected
but won't be stored or queryable.

### 5. Classify findings

For each deployment, assign a status:

| Status | Meaning |
|---|---|
| `instrumented` | Already has auto-instrumentation annotations or OTel env vars |
| `partially-instrumented` | Has some OTel config but missing key pieces (e.g., env vars but no exporter endpoint) |
| `uninstrumented` | No tracing instrumentation detected |
| `skipped` | Zero replicas, infrastructure component, or operator-managed |

Skip known infrastructure deployments (operators, controllers, DNS, ingress,
monitoring agents) — they typically should not be auto-instrumented.

### 6. Produce recommendations

For each `uninstrumented` deployment, recommend:

1. The annotation to add to the deployment
2. The detected or suggested language
3. Whether an `Instrumentation` CR needs to be created (use the provided CR, or
   auto-generate one from the discovered collector endpoint)

## Execution Phase

### 1. Create Instrumentation CR (if needed)

If the CR already exists in the namespace, skip this step:

```bash
oc get instrumentations.opentelemetry.io -n <namespace>
```

**If an `Instrumentation` CR was provided in the proposal request**, apply it
as-is to the target namespace.

**If no CR was provided**, create one by discovering the collector endpoint from
existing `OpenTelemetryCollector` CRs:

```bash
oc get opentelemetrycollectors -A -o json | \
  jq -r '.items[0] | "\(.metadata.name)-collector.\(.metadata.namespace).svc.cluster.local:4317"'
```

Then apply:

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: auto-instrumentation
  namespace: <target-namespace>
spec:
  exporter:
    endpoint: http://<discovered-collector-service>:4317
  propagators:
    - tracecontext
    - baggage
```

If no collector can be discovered, report it as a blocker — the agent must not
create an `Instrumentation` CR with a fabricated endpoint.

### 2. Annotate deployments

For each uninstrumented deployment, patch the **deployment's pod template** with
the language-specific annotation. **Never annotate the namespace** — namespace-level
annotations do not specify a language and will not trigger auto-instrumentation.
Each deployment must be patched individually:

```bash
oc patch deployment <name> -n <namespace> --type merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-<language>":"auto-instrumentation"}}}}}'
```

Where `<language>` is one of: `java`, `python`, `nodejs`, `dotnet`, `go`, `sdk`.

This triggers a rolling restart. The OTel operator webhook intercepts the pod
creation and injects the auto-instrumentation init container.

### 3. Wait for rollout

```bash
oc rollout status deployment/<name> -n <namespace> --timeout=120s
```

## Verification Phase

After instrumentation is applied, verify traces are flowing:

### 1. Check init containers were injected

```bash
oc get pods -n <namespace> -l app=<deployment-name> -o json | \
  jq '.items[0].spec.initContainers[]? | select(.name | startswith("opentelemetry-auto-instrumentation"))'
```

### 2. Check OTel environment variables are set

```bash
oc get pods -n <namespace> -l app=<deployment-name> -o json | \
  jq '.items[0].spec.containers[0].env[] | select(.name | startswith("OTEL_"))'
```

### 3. Check collector is receiving spans

Query the collector's own metrics to verify spans are being received:

```bash
oc exec -n <collector-namespace> <collector-pod> -- \
  curl -s localhost:8888/metrics | grep otelcol_receiver_accepted_spans
```

The `otelcol_receiver_accepted_spans` counter should be incrementing.

### 4. Verify traces in Tempo (if available)

If a TempoStack or TempoMonolithic is deployed, query for recent traces from the
instrumented service:

```bash
oc exec -n <tempo-namespace> <tempo-pod> -- \
  curl -sG "http://localhost:3200/api/search" --data-urlencode 'q=resource.service.name=<service-name>' --data-urlencode 'limit=5'
```

Or via the Tempo gateway if using TempoStack with multi-tenancy.

## Failure Modes — What NOT to Do

1. **Never auto-instrument infrastructure or operator pods.** Only instrument
   user workloads — application deployments that serve business logic.

2. **Never create an Instrumentation CR with a fabricated endpoint.** If a CR
   was provided in the request, apply it as-is. If not, discover the collector
   endpoint from existing `OpenTelemetryCollector` CRs. If no collector exists,
   report it as a blocker.

3. **Never assume the language.** If the image doesn't clearly indicate the
   runtime, ask the user or recommend `inject-sdk`.

4. **Never instrument a deployment that already has instrumentation.** This can
   cause double-tracing, duplicate spans, or init-container conflicts.

5. **Never skip the prerequisite check.** If the OTel operator is not installed,
   the annotations will have no effect and the user will see no improvement.

6. **Never force-restart pods in production without user awareness.** Annotating
   a deployment triggers a rolling restart — the analysis must note this.

7. **Never modify a user-provided Instrumentation CR.** If the proposal includes
   a CR, apply it as-is. The user is responsible for the collector endpoint and
   propagator configuration.

8. **Never annotate the namespace to inject instrumentation.** Always patch each
   deployment's pod template spec individually with a language-specific annotation
   (e.g., `inject-java`, `inject-python`). Namespace-level annotations like
   `instrumentation.opentelemetry.io/inject: "true"` do not specify a language
   and will not trigger the OTel operator webhook.

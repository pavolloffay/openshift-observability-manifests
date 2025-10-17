# Export metrics from in-cluster monitoring stack to OpenTelemetry collector

This directory contains manifest files for exporting metrics from OpenShift in-cluster monitoring stack to an OpenTelemetry collector.

The in-cluster monitoring exports metrics via Prometheus remote write protocol.

OTEL Remote write receiver https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/prometheusremotewritereceiver#metadata-wal-records-feature-flag


Because the in-cluster monitoring stack Prometheus does not support [remote write v2 protocol](https://issues.redhat.com/browse/OBSDA-1241),
we have tried a workaround by deploying the Cluster Observability Operator (COO) and configuring remote-write from in-cluster monitoring stack to the `MonitoringStack` CR created by COO and then to the OTEL collector.
This setup works after enabling the `--enable-feature=metadata-wal-records` and `--enable-feature=native-histograms` flags in the Prometheus instance deployed by COO.
However, the in-cluster monitoring stack collects classic histograms which OTEL does not support and they are dropped with a warning in the OTEL collector logs.

## Testing setup

See [OCP screenshot](./ocp-screenshot.png). It seems like the COO prometheus instance is under much higher load than the final "vendor" prometheus which receives data via OTLP from the OTELcol.

* coo prometheus `k port-forward prometheus-coo-monitoring-stack-0 9090:9090` http://localhost:9090/query?g0.expr=prometheus_remote_storage_samples_in_total&g0.show_tree=0&g0.tab=graph&g0.range_input=1h&g0.res_type=auto&g0.res_density=medium&g0.display_mode=lines&g0.show_exemplars=0&g1.expr=node_network_up&g1.show_tree=0&g1.tab=graph&g1.range_input=6h&g1.res_type=auto&g1.res_density=medium&g1.display_mode=lines&g1.show_exemplars=0&g2.expr=prometheus_remote_storage_samples_dropped_total&g2.show_tree=0&g2.tab=table&g2.range_input=1h&g2.res_type=auto&g2.res_density=medium&g2.display_mode=lines&g2.show_exemplars=0
* vendor prometheus `k port-forward prometheus-vendor-0 9091:9090` http://localhost:9091/query?g0.expr=prometheus_remote_storage_samples_in_total&g0.show_tree=0&g0.tab=table&g0.range_input=1h&g0.res_type=auto&g0.res_density=medium&g0.display_mode=lines&g0.show_exemplars=0&g1.expr=node_network_up&g1.show_tree=0&g1.tab=graph&g1.end_input=2025-10-17+16%3A02%3A18&g1.moment_input=2025-10-17+16%3A02%3A18&g1.range_input=6h&g1.res_type=auto&g1.res_density=medium&g1.display_mode=lines&g1.show_exemplars=0 

The issue is that a metrics `node_network_up` has 28 instance in in-cluster prometheus, the COO receives all 28 instances but the final vendor prometheus receives only 16 instances.

Also note this issue https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/43628 - collector stops receiving data after some time.

## Issues

### OTEL requires `--enable-feature=metadata-wal-records`

This flag is not enabled in the in-cluster monitoring stack Prometheus.

Solution: deploy COO and override the Prometheus CR.

```yaml
#  kubectl apply -f coo-prometheus.yaml --server-side
apiVersion: monitoring.rhobs/v1
kind: Prometheus
metadata:
  name: coo-monitoring-stack
spec:
  enableFeatures:
    - native-histograms
```

### OTEL supports only remote-write v2

The in-cluster monitoring stack does not support remote-write v2 protocol.

Solution: deploy COO and set the `messageVersion: V2.0` in the Prometheus remote write configuration.

```yaml
apiVersion: monitoring.rhobs/v1alpha1
kind: MonitoringStack
metadata:
  name: coo-monitoring-stack
  namespace: observability
spec:
  logLevel: debug
  retention: 7d
  resourceSelector:
    matchLabels:
      app: observability
  alertmanagerConfig:
    disabled: true
  prometheusConfig:
    replicas: 1
    enableOtlpHttpReceiver: true
    remoteWrite:
    - url: http://otel-collector.observability.svc.cluster.local:9090/api/v1/write
      messageVersion: V2.0
      sendExemplars: true
      sendNativeHistograms: true
```

### OTEL does not support receiving classic histograms

OTEL collector logs the following warning:
```bash
{"level":"info","ts":"2025-10-13T15:52:29.276Z","caller":"prometheusremotewritereceiver@v0.136.0/receiver.go:407","msg":"Dropping classic histogram series. Please configure Prometheus to convert classic histograms into Native Histograms Custom Buckets","resource":{"service.instance.id":"7e80f7b9-6f86-4469-bbec-44f99c44883c","service.name":"otelcol-contrib","service.version":"0.136.0"},"otelcol.component.id":"prometheusremotewrite","otelcol.component.kind":"receiver","otelcol.signal":"metrics","timeseries":"prometheus_http_response_size_bytes_bucket"}
```

The OTEL collector does not support classic histograms. Prometheus does not internally or via remote-write convert the classic histograms into native histograms.
The conversion can be configured only at the metrics scraping time.


The conversion from classic fixed-bucket histograms to the flexible NHCB format is controlled on a per-scrape-job basis. This tells Prometheus to perform the conversion when it encounters a classic histogram format.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app-monitor
spec:
  # ... other configuration ...
  endpoints:
    - port: http-metrics
      interval: 30s
      scrapeConfig:
        # This is the key setting for conversion:
        convertClassicHistograms: true 
```

On top of this the native histograms need to be enabled in the Prometheus instance configuration.

```yaml
apiVersion: monitoring.rhobs/v1
kind: Prometheus
metadata:
  name: coo-monitoring-stack
spec:
  enableFeatures:
    - metadata-wal-records
    - native-histograms
```

### prometheusremotewrite http: panic serving: invalid access to shared data

https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/41347#issuecomment-3415872210

Essentially the receiver panics if multiple exporters are specified.


### The OTEL col stops receiving data 

https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/43628

## Final Prometheus CR

Below is the final Prometheus CR deployed by COO.

Important parts are:
```yaml
    convertClassicHistogramsToNHCB: true
    enableFeatures:
      - otlp-write-receiver
      - metadata-wal-records
      - native-histograms
    remoteWrite:
      - messageVersion: V2.0
        sendExemplars: true
        sendNativeHistograms: true
        url: http://otel-collector.observability.svc.cluster.local:9090/api/v1/write
```

Even with this configuration the classic histograms are still dropped in the OTEL collector with the same warning as above:

```bash
{"level":"info","ts":"2025-10-15T08:20:31.925Z","caller":"prometheusremotewritereceiver@v0.136.0/receiver.go:407","msg":"Dropping classic histogram series. Please configure Prometheus to convert classic histograms into Native Histograms Custom Buckets","resource":{"service.instance.id":"e7c5cb83-232b-4b6e-af63-4e720f8baf02","service.name":"otelcol-contrib","service.version":"0.136.0"},"otelcol.component.id":"prometheusremotewrite","otelcol.component.kind":"receiver","otelcol.signal":"metrics","timeseries":"prometheus_http_response_size_bytes_bucket"}
```

Maybe the issue is related to https://github.com/prometheus/prometheus/issues/17075?


```yaml
apiVersion: v1
items:
- apiVersion: monitoring.rhobs/v1
  kind: Prometheus
  metadata:
    creationTimestamp: "2025-10-15T08:13:40Z"
    generation: 2
    labels:
      app.kubernetes.io/managed-by: observability-operator
      app.kubernetes.io/name: coo-monitoring-stack
      app.kubernetes.io/part-of: coo-monitoring-stack
    name: coo-monitoring-stack
    namespace: observability
    ownerReferences:
    - apiVersion: monitoring.rhobs/v1alpha1
      blockOwnerDeletion: true
      controller: true
      kind: MonitoringStack
      name: coo-monitoring-stack
      uid: 12e156d3-ff30-4364-8bc8-f6efd68f2e25
    resourceVersion: "140359"
    uid: 8cd9069a-8faa-4833-a494-41bce16ba7cf
  spec:
    additionalScrapeConfigs:
      key: self-scrape-config
      name: coo-monitoring-stack-self-scrape
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/component: prometheus
              app.kubernetes.io/part-of: coo-monitoring-stack
          topologyKey: kubernetes.io/hostname
    arbitraryFSAccessThroughSMs: {}
    convertClassicHistogramsToNHCB: true
    enableFeatures:
    - otlp-write-receiver
    - metadata-wal-records
    - native-histograms
    evaluationInterval: 30s
    logLevel: debug
    podMetadata:
      labels:
        app.kubernetes.io/component: prometheus
        app.kubernetes.io/part-of: coo-monitoring-stack
    podMonitorSelector:
      matchLabels:
        app: observability
    portName: web
    probeSelector:
      matchLabels:
        app: observability
    remoteWrite:
    - messageVersion: V2.0
      sendExemplars: true
      sendNativeHistograms: true
      url: http://otel-collector.observability.svc.cluster.local:9090/api/v1/write
    replicas: 1
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
      requests:
        cpu: 100m
        memory: 256Mi
    retention: 7d
    ruleSelector:
      matchLabels:
        app: observability
    rules:
      alert: {}
    scrapeConfigSelector:
      matchLabels:
        app: observability
    scrapeInterval: 30s
    securityContext:
      fsGroup: 65534
      runAsNonRoot: true
      runAsUser: 65534
    serviceAccountName: coo-monitoring-stack-prometheus
    serviceMonitorSelector:
      matchLabels:
        app: observability
    thanos:
      blockSize: 2h
      image: quay.io/thanos/thanos:v0.38.0
      resources: {}
```

## Example app deployment

The metrics from the example app are successfully forwarded to the OTEL collector with a native histogram. Config:

```yaml
    remoteWrite:
    - url: http://otel-collector.observability.svc.cluster.local:9090/api/v1/write
      messageVersion: V2.0
      sendExemplars: true
      sendNativeHistograms: true
      writeRelabelConfigs:
        # This configuration keeps only metrics from the example-app service which uses native histograms
        - sourceLabels: [ service ]  # The label to inspect
          regex: 'example-app'           # The value to match (e.g., 'production')
          action: keep                  # Only KEEP metrics that match the regex
```

However if the `writeRelabelConfigs` is not specified then the classic histograms from COO reach the OTEL collector and are dropped with a warning.


The app is https://github.com/pavolloffay/prometheus-example-app/tree/native-histogram and uses native histograms.


# Export metrics from in-cluster monitoring stack to OpenTelemetry collector

This directory contains manifest files for exporting metrics from OpenShift in-cluster monitoring stack to an OpenTelemetry collector.

The in-cluster monitoring exports metrics via Prometheus remote write protocol.

OTEL Remote write receiver https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/prometheusremotewritereceiver#metadata-wal-records-feature-flag


Because the in-cluster monitoring stack Prometheus does not support [remote write v2 protocol](https://issues.redhat.com/browse/OBSDA-1241),
we have tried a workaround by deploying the Cluster Observability Operator (COO) and configuring remote-write from in-cluster monitoring stack to the `MonitoringStack` CR created by COO and then to the OTEL collector.
This setup works after enabling the `--enable-feature=metadata-wal-records` and `--enable-feature=native-histograms` flags in the Prometheus instance deployed by COO.
However, the in-cluster monitoring stack collects classic histograms which OTEL does not support and they are dropped with a warning in the OTEL collector logs.

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
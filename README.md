# OpenShift observability setup

This directory contains manifest files for deploying end-to-end observability stack on OpenShift for metrics, logs and traces.

## Deploy

1. Install operators
```bash
kubectl apply -f 00-install-operators
```

2. Install logging
```bash
kubectl apply -f logging
```

3. Install monitoring
```bash
kubectl apply -f metrics
```

4. Install tracing
```bash
kubectl apply -f tracing
```

5. Install OpenTelemetry collector

```bash
kubectl apply -f 00-create-namespace.yaml
kubectl apply -f 01-deploy-otel-collector.yaml
```

## Forward data to OpenTelemetry collector

The telemetry data should be forwarded to the OpenTelemetry collector in the `otel-observability` namespace.

```bash
kubectl get svc -n otel-observability
NAME                       TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)                                                                     AGE
dev-collector              ClusterIP   10.217.5.163   <none>        14250/TCP,4317/TCP,4318/TCP,14268/TCP,6831/UDP,6832/UDP,8889/TCP,9411/TCP   39m
dev-collector-headless     ClusterIP   None           <none>        14250/TCP,4317/TCP,4318/TCP,14268/TCP,6831/UDP,6832/UDP,8889/TCP,9411/TCP   39m
dev-collector-monitoring   ClusterIP   10.217.4.175   <none>        8888/TCP
 ```
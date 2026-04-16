# OpenTelemetry collector Guaranteed Delivery

These two approaches are mutually exclusive - the collector config validation rejects using both `storage` and `wait_for_result` together.

## Use file_storage extension (persistent queue)

The exporter's `sending_queue.storage` is set to a `file_storage` extension. The collector persists queued items to disk.
The caller (pipeline) blocks only until the item is **written to disk**, not until the export succeeds.
If the collector crashes or restarts, the queued items are recovered from disk and re-exported.

Requires `mode: statefulset` with a PVC. See [otelcol.yaml](otelcol-file-storage.yaml).

## Use exporters in-memory queue with sending_queue.wait_for_result

The exporter's `sending_queue.wait_for_result` is set to `true` (without `storage`). The caller blocks until the item is **fully exported** to the backend.
If the export fails, the error propagates back through the pipeline to the receiver, which can apply backpressure (e.g. return an error to the OTLP sender).
However, if the collector crashes before the export completes, the in-flight data is lost.

## Audit logs

Kubernetes API server audit logs can be collected with the `filelog` receiver.
The kube-apiserver does not support OTLP - it writes audit events in `audit.k8s.io/v1` JSON format to files on control plane nodes.

On OpenShift the audit log sources are:

| Source | Description | File Path |
|--------|-------------|-----------|
| kubeAPI | Kubernetes API server audit logs | `/var/log/kube-apiserver/audit.log` |
| openshiftAPI | OpenShift API server audit logs | `/var/log/openshift-apiserver/audit.log`, `/var/log/oauth-apiserver/audit.log`, `/var/log/oauth-server/audit.log` |
| auditd | Linux auditd daemon logs from nodes | `/var/log/audit/audit.log` |
| ovn | Open Virtual Network ACL audit logs | `/var/log/ovn/acl-audit-log.log` |

See [otelcol-audit-logs.yaml](otelcol-audit-logs.yaml).

For guaranteed delivery, configure the `filelog` receiver with a `storage` extension (e.g. `file_storage`).
Without it, file offsets are in-memory only and lost on crash (the `start_at` setting applies on restart, defaulting to `"end"` which skips all logs written while the collector was down).
With `storage` configured, the receiver persists file offsets (byte position, fingerprint, record count) to disk under the key `knownFiles` and resumes from the last known offset on restart.

The `start_at` field accepts `beginning` or `end` (default). It only applies on the very first start when no checkpoint exists in storage.
When checkpoints exist, `start_at` is ignored and the receiver resumes from the persisted offset.
Use `start_at: beginning` so that on first deploy (or after storage reset) the full file is read instead of skipping existing logs.

```yaml
receivers:
  filelog:
    include:
      - /var/log/kube-apiserver/audit.log
    start_at: beginning
    storage: file_storage/persistent_queue
```


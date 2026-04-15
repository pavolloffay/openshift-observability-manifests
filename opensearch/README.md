# OpenSearch as alternative for Loki and Tempo

Evaluation of OpenSearch as a unified backend for logs (replacing Loki) and traces (replacing Tempo) on OpenShift.

## Architecture

OpenSearch uses [Data Prepper](https://docs.opensearch.org/latest/data-prepper/) as its ingestion pipeline. Data Prepper accepts OTLP (gRPC/HTTP) via the unified [`otlp` source](https://docs.opensearch.org/latest/data-prepper/pipelines/configuration/sources/otlp-source/) (since 2.12), so the OTel Collector can export directly to it. For traces, three internal pipelines correlate spans into traces and compute service maps before indexing.

```
OTel Collector --OTLP--> Data Prepper ---> OpenSearch
                                            |
                                      OpenSearch Dashboards
                                      (Trace Analytics plugin)
```

Alternatively, the OTel Collector `opensearch` exporter (contrib) can write directly to OpenSearch, bypassing Data Prepper -- but loses service map computation and span correlation.

## Tracing (replacing Tempo)

| Capability | Tempo | OpenSearch |
|---|---|---|
| **Query model** | Trace ID lookup + limited tag search (vParquet) | Full inverted index on all span fields, arbitrary boolean queries, aggregations |
| **Search by duration/percentiles** | Limited (TraceQL) | Native aggregations and percentile queries |
| **Service map** | Grafana plugin (client-side) | Server-side computation via Data Prepper |
| **Visualization** | Grafana (Tempo data source) | [Trace Analytics plugin](https://docs.opensearch.org/latest/observing-your-data/trace/ta-dashboards/) -- service maps, latency histograms, waterfall diagrams |
| **Storage** | Object storage (S3/MinIO) | Block storage (PVCs) for hot data, object storage for cold tier |
| **Multi-tenancy** | Gateway + OIDC, tenant-scoped RBAC | Security plugin: silo (index-per-tenant), pool (document-level security), or hybrid |

OpenSearch provides stronger ad-hoc trace search. Tempo is more storage-efficient for high-volume write-heavy workloads.

## Logging (replacing Loki)

| Capability | Loki | OpenSearch |
|---|---|---|
| **Indexing** | Labels only (pod, namespace, container); brute-force scans log content | Full-text inverted index on every field |
| **Full-text search** | Slow for grep-style queries across large volumes | Fast arbitrary text search |
| **Query language** | LogQL | OpenSearch DSL, SQL, PPL |
| **Lifecycle management** | Simple retention config | [ISM policies](https://docs.opensearch.org/latest/im-plugin/ism/index/) -- rollover, hot/warm/cold tiers, force merge, deletion |
| **Storage** | Object storage (S3/MinIO) | Block storage (PVCs) primary, object storage for snapshots/cold |

OpenSearch is significantly better for "needle in haystack" log queries. Loki is adequate when queries can be narrowed by labels first and uses far less storage.

## OpenShift Integration

**History:** OpenShift originally shipped with the EFK stack (Elasticsearch, Fluentd, Kibana). Red Hat deprecated Elasticsearch in logging 5.x and migrated to Loki in 6.0. OpenSearch (the Elasticsearch fork post-license-change) was never part of the official OpenShift logging stack.

**Operators:**
- [opensearch-k8s-operator](https://github.com/opensearch-project/opensearch-k8s-operator) (community, v3.0 alpha/beta) -- requires SCC adjustments (`setVMMaxMapCount: false`) for OpenShift
- [Stackable Operator for OpenSearch](https://catalog.redhat.com/en/software/containers/stackable/stackable-opensearch-operator/692716b8b83e190c19b5f8b8) -- listed in Red Hat Ecosystem Catalog as certified

**Red Hat support:** OpenSearch is **not supported** by Red Hat as part of the OpenShift observability stack. No Red Hat-provided operator exists.

## Resource Requirements

Resource comparison using the official Red Hat T-shirt sizes from [LokiStack sizing](https://docs.redhat.com/en/documentation/red_hat_openshift_logging/6.5/html/configuring_logging/configuring-lokistack-storage#loki-sizing_configuring-the-log-store) and [TempoStack sizing](https://107838--ocpdocs-pr.netlify.app/openshift-enterprise/latest/observability/distr_tracing/distr-tracing-tempo-configuring.html#distr-tracing-tempo-config-size_distr-tracing-tempo-configuring). Both use replication factor 2.

OpenSearch estimates assume a single data type (logs or traces, not both) at the same ingestion rate as each LokiStack/TempoStack tier, with 15-day retention, replication factor 2, and block storage (SSD PVCs). Storage formula: `daily_data x 1.25 (indexing overhead) x 2 (replicas) x 15 days`. JVM heap set to 50% of RAM (max 31.5 GB per node). RAM is sized using the [1:30 memory-to-stored-data ratio](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/sizing-domains.html) recommended by AWS for hot-tier nodes (see also [Elastic sizing blog](https://www.elastic.co/blog/benchmarking-and-sizing-your-elasticsearch-cluster-for-logs-and-metrics)).

### LokiStack (from Red Hat docs)

| | 1x.pico | 1x.extra-small | 1x.small | 1x.medium |
|---|---|---|---|---|
| **Data transfer** | 50 GB/day | 100 GB/day | 500 GB/day | 2 TB/day |
| **QPS** | 1-25 at 200ms | 1-25 at 200ms | 25-50 at 200ms | 25-75 at 200ms |
| **Replication factor** | 2 | 2 | 2 | 2 |
| **Total CPU requests** | 7 vCPUs | 14 vCPUs | 34 vCPUs | 54 vCPUs |
| **Total memory requests** | 17 Gi | 31 Gi | 67 Gi | 139 Gi |
| **Total disk requests** | 590 Gi | 430 Gi | 430 Gi | 590 Gi |

### TempoStack (from Red Hat docs)

| | 1x.pico | 1x.extra-small | 1x.small | 1x.medium |
|---|---|---|---|---|
| **Ingestion rate** | Small workloads | 100 GB/day | 500 GB/day | 2 TB/day |
| **Replication factor** | 2 | 2 | 2 | 2 |
| **Total CPU requests** | 3.25 vCPUs | 4.6 vCPUs | 7.9 vCPUs | 24 vCPUs |
| **Total CPU (with gateway + Jaeger UI)** | 3.6 vCPUs | 5.6 vCPUs | 9.7 vCPUs | 32.3 vCPUs |
| **Total memory requests** | 8.8 Gi | 22.1 Gi | 30.1 Gi | 47.1 Gi |
| **Total memory (with gateway + Jaeger UI)** | 9 Gi | 22.5 Gi | 30.7 Gi | 47.7 Gi |

### OpenSearch (replacing LokiStack or TempoStack)

OpenSearch resources are the same whether indexing logs or traces -- the cluster doesn't differentiate between document types. The table below shows an OpenSearch cluster handling a single data type at the same ingestion rate as each LokiStack/TempoStack tier. At pico scale, master and data roles are combined on the same nodes.

**How the numbers are calculated:**

**Disk (stored data):** `daily_ingestion x 1.25 (indexing overhead: segment metadata, transaction logs, merge headroom) x 2 (replication factor) x 15 (retention days)`. Example for 500 GB/day: `500 x 1.25 x 2 x 15 = 18,750 GB = 18.75 TB`.

**RAM (data nodes):** The industry-standard guideline is a **1:30 memory-to-stored-data ratio** for hot-tier nodes ([AWS sizing guide](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/sizing-domains.html), [Elastic sizing blog](https://www.elastic.co/blog/benchmarking-and-sizing-your-elasticsearch-cluster-for-logs-and-metrics), [Opster capacity planning](https://opster.com/guides/opensearch/opensearch-capacity-planning/memory-usage/)). This means 30 GB of stored data requires 1 GB of RAM. The RAM is split roughly 50/50: half goes to the JVM heap (capped at 31.5 GB for compressed OOPs) for indexing buffers, field data caches, query caches, and segment metadata; the other half is left for the OS filesystem cache which keeps frequently accessed index segments in memory for fast reads. Example for 500 GB/day: `18,750 GB / 30 = 625 Gi` total RAM needed, divided by 64 GB per node = `625 / 64 ≈ 10 data nodes`.

**CPU (data nodes):** Driven by indexing throughput and search concurrency. Each vCPU handles roughly 5-10 MB/s of indexing throughput depending on mapping complexity. At 500 GB/day (~5.8 MB/s average, but peak can be 2-3x), 10 nodes with 8 CPUs each provides headroom for burst traffic and concurrent search queries. At 2 TB/day (~23 MB/s average), 40 nodes x 8 CPUs handles ~16 MB/s indexing capacity per node plus search load.

**Dedicated master nodes:** Recommended for all production clusters ([AWS best practices](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/managedomains-dedicatedmasternodes.html)). Masters manage cluster state (shard allocation, index metadata, node membership) and do not hold data. Combining master and data roles on the same nodes is a common cost optimization for very small clusters (3 nodes), but is not recommended for production because data node operations -- heavy indexing, long GC pauses, expensive queries -- can starve the master role and cause cluster instability (missed heartbeats, shard allocation delays, split-brain risk). Sized at 2-4 CPU / 8-16 GB depending on cluster size.

**Data Prepper:** Ingestion pipeline that receives OTLP data and writes to OpenSearch. Scales at ~1 instance (2 CPU, 4-8 GB) per 50 GB/day of ingestion. For logs, Data Prepper is essentially passthrough -- it receives log documents via OTLP and writes them to OpenSearch with minimal buffering. For traces, Data Prepper runs three chained pipelines:

- **`entry-pipeline`** -- accepts OTLP spans from the OTel Collector and fans out to the other two pipelines. No processing itself.
- **`raw-trace-pipeline`** -- runs the `otel_traces` processor which performs stateful trace-group enrichment: buffers spans by trace ID, identifies the root span, and copies the root span's operation name into a `traceGroup` field on every span in the trace. This enables filtering/aggregating spans by the top-level operation that initiated the trace (e.g. "show all spans triggered by `POST /api/checkout`"). Writes to `otel-v1-apm-span-*` index. **Required** -- without it spans don't reach OpenSearch.
- **`service-map-pipeline`** -- runs the `service_map` processor which aggregates parent-child relationships across spans to build a service dependency graph. Writes to `otel-v1-apm-service-map` index. **Optional** -- can be disabled if the Service Map visualization in OpenSearch Dashboards is not needed.

The raw-trace and service-map pipelines must **buffer spans in memory** for a configurable window (default 30 seconds). This span buffering is why trace instances need more RAM (8 Gi vs 4 Gi).

Data Prepper can also be **bypassed entirely** by using the OTel Collector's `opensearch` exporter to write spans directly to OpenSearch. This gives raw span storage and basic search, but loses trace-group enrichment (`traceGroup` field not populated, so filtering by root operation breaks) and service map generation. The Trace Analytics dashboards in OpenSearch will be partially broken without Data Prepper.

| | pico (50 GB/day) | extra-small (100 GB/day) | small (500 GB/day) | medium (2 TB/day) |
|---|---|---|---|---|
| **Stored data** | 1.9 TB | 3.75 TB | 18.75 TB | 75 TB |
| **RAM needed (1:30)** | 63 Gi | 125 Gi | 625 Gi | 2,500 Gi |
| **Data nodes** | 3 | 3 | 10 | 40 |
| **Data node spec** | 4 CPU, 32 GB | 8 CPU, 64 GB | 8 CPU, 64 GB | 8 CPU, 64 GB |
| **Dedicated masters** | 3x (2 CPU, 8 GB) | 3x (2 CPU, 8 GB) | 3x (2 CPU, 8 GB) | 3x (4 CPU, 16 GB) |
| **Data Prepper (logs)** | 1x (2 CPU, 4 GB) | 2x (2 CPU, 4 GB) | 4x (2 CPU, 8 GB) | 8x (2 CPU, 8 GB) |
| **Data Prepper (traces)** | 1x (2 CPU, 8 GB) | 2x (2 CPU, 8 GB) | 4x (2 CPU, 8 GB) | 8x (2 CPU, 8 GB) |
| **Total CPU** | 20 vCPUs | 34 vCPUs | 102 vCPUs | 348 vCPUs |
| **Total memory** | 124-128 Gi | 224-232 Gi | 696-712 Gi | 2,672-2,704 Gi |
| **Disk (SSD PVCs)** | 1.9 TB | 3.75 TB | 18.75 TB | 75 TB |

The memory range reflects Data Prepper: lower bound is for log pipelines (4 Gi/instance), upper bound is for trace pipelines (8 Gi/instance). The OpenSearch cluster itself is identical in both cases.

### Side-by-Side: OpenSearch vs LokiStack (logs only, same ingestion rate)

| Size | | LokiStack | OpenSearch | Ratio |
|------|------|-----------|-----------|-------|
| **1x.pico** | CPU | 7 vCPUs | 20 vCPUs | **2.9x** |
| (50 GB/day) | RAM | 17 Gi | 124 Gi | **7.3x** |
| | Disk | 590 Gi local + obj storage | 1.9 TB SSD | SSD vs obj storage |
| **1x.extra-small** | CPU | 14 vCPUs | 34 vCPUs | **2.4x** |
| (100 GB/day) | RAM | 31 Gi | 224 Gi | **7.2x** |
| | Disk | 430 Gi local + obj storage | 3.75 TB SSD | SSD vs obj storage |
| **1x.small** | CPU | 34 vCPUs | 102 vCPUs | **3x** |
| (500 GB/day) | RAM | 67 Gi | 696 Gi | **10.4x** |
| | Disk | 430 Gi local + obj storage | 18.75 TB SSD | SSD vs obj storage |
| **1x.medium** | CPU | 54 vCPUs | 348 vCPUs | **6.4x** |
| (2 TB/day) | RAM | 139 Gi | 2,672 Gi | **19.2x** |
| | Disk | 590 Gi local + obj storage | 75 TB SSD | SSD vs obj storage |

**Note on TempoStack comparison:** The OpenSearch resources are identical whether replacing LokiStack or TempoStack (same ingestion rate = same cluster). The ratios would be even more dramatic for traces because TempoStack is significantly leaner than LokiStack -- for example at `1x.medium`, TempoStack needs only 32.3 vCPUs / 47.7 Gi (vs LokiStack's 54 vCPUs / 139 Gi) for the same 2 TB/day rate. This is because Tempo stores compressed traces on object storage with minimal indexing, while Loki still indexes labels and stores log chunks.

OpenSearch memory estimates are based on the industry-standard [1:30 memory-to-stored-data ratio](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/sizing-domains.html) for hot-tier nodes. Write-heavy workloads with simple queries could use a 1:64 ratio (roughly halving the RAM), but this is not recommended for production search workloads. See also [Opster capacity planning](https://opster.com/guides/opensearch/opensearch-capacity-planning/memory-usage/) and [Elastic sizing blog](https://www.elastic.co/blog/benchmarking-and-sizing-your-elasticsearch-cluster-for-logs-and-metrics).

## Log-Trace Correlation

OpenSearch can correlate logs and traces by indexing the `trace_id` field in both log and span documents, then joining in Dashboards. However, this only works if OpenSearch receives **both** logs and traces -- if it replaces only one of LokiStack or TempoStack, correlation must still go through Grafana cross-linking with the other system. Using OpenSearch for both data types doubles the resource requirements shown above.

In the Grafana stack (current setup), Tempo and Loki provide native cross-linking via data source configuration with zero custom indexing.

## Verdict

| | Loki + Tempo (current) | OpenSearch |
|---|---|---|
| **Search power** | Label-based (Loki), TraceQL (Tempo) | Full-text search on everything |
| **Resource cost** | Low (object-storage-native) | High (JVM + block storage) |
| **Red Hat support** | Fully supported, operators provided | Not supported |
| **Operational complexity** | Managed by Red Hat operators | JVM tuning, shard management, capacity planning |
| **Strategic direction** | Aligned with Red Hat (LGTM stack) | Goes against Red Hat's direction |
| **Single backend** | Two separate systems | One system for logs + traces |
| **Alerting** | Grafana alerting | Built-in alerting + anomaly detection |

**OpenSearch makes sense when:** full-text search across logs and traces is a hard requirement, the team has Elasticsearch/OpenSearch expertise, and Red Hat support is not needed.

**Loki + Tempo is better when:** cost efficiency, Red Hat support, and alignment with the OpenShift platform strategy matter more than raw search capability.

## References
* [LokiStack sizing -- Red Hat OpenShift Logging 6.5](https://docs.redhat.com/en/documentation/red_hat_openshift_logging/6.5/html/configuring_logging/configuring-lokistack-storage#loki-sizing_configuring-the-log-store)
* [TempoStack sizing -- Red Hat Distributed Tracing](https://107838--ocpdocs-pr.netlify.app/openshift-enterprise/latest/observability/distr_tracing/distr-tracing-tempo-configuring.html#distr-tracing-tempo-config-size_distr-tracing-tempo-configuring)
* [AWS OpenSearch sizing domains](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/sizing-domains.html) -- 1:30 memory:data ratio for hot tier
* [Elastic: benchmarking and sizing for logs and metrics](https://www.elastic.co/blog/benchmarking-and-sizing-your-elasticsearch-cluster-for-logs-and-metrics)
* [Elastic: sizing hot-warm architectures](https://www.elastic.co/blog/sizing-hot-warm-architectures-for-logging-and-metrics-in-the-elasticsearch-service-on-elastic-cloud)
* [Opster: OpenSearch memory usage and capacity planning](https://opster.com/guides/opensearch/opensearch-capacity-planning/memory-usage/)
* [Grafana Loki vs Elasticsearch](https://medium.com/engenharia-arquivei/grafana-loki-our-journey-on-replacing-elastic-search-and-adopting-a-new-logging-solution-at-f65aec407e47)
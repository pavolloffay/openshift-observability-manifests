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

### How indexing works

OpenSearch stores data in **indices** -- each index is a set of shards distributed across data nodes, with a full inverted index on every field. This is fundamentally different from Loki (label index + compressed chunks on object storage) and Tempo (block index + bloom filters on object storage). The full inverted index enables arbitrary field queries but costs ~1.5-2x raw data size in storage (vs ~0.3-0.5x for Loki/Tempo with compression).

**Default indices created by Data Prepper:**
- `otel-v1-apm-span-*` -- enriched trace spans (one document per span)
- `otel-v1-apm-service-map` -- service dependency graph
- Log index name is configurable (e.g. `otel-v1-logs-YYYY.MM.dd`)

**Index rotation:** OpenSearch does not rotate indices automatically. By default, Data Prepper writes to a single index that grows indefinitely -- this is problematic because OpenSearch can only delete entire indices, not individual documents by age. A single unbounded index also grows shards beyond the recommended 10-50 GB limit, degrading search performance and increasing recovery time. The standard pattern is time-based indices (e.g. `otel-v1-apm-span-2026.04.15`) so old data can be removed by simply dropping old indices. This requires explicit configuration -- either a date pattern in the Data Prepper sink config or an [ISM rollover policy](https://docs.opensearch.org/latest/im-plugin/ism/index/). Rollover can be triggered by age (e.g. 1 day), size (e.g. 30 GB), or document count.

**Retention:** Managed via [ISM policies](https://docs.opensearch.org/latest/im-plugin/ism/index/) that transition indices through states: `hot` (active writes/queries) -> `delete` (after `min_index_age`). ISM is a built-in OpenSearch plugin (`opensearch-index-management`) -- it runs as a background job inside the cluster (default every 5 minutes), checking each managed index against its policy. No external cron or Data Prepper involvement needed. Policies are attached to indices via index pattern templates. Without an ISM policy, old indices are never deleted. This contrasts with Loki/Tempo where retention is a simple declarative field in the CR.

**Shards:** Default is 1 primary shard + 1 replica per index. More primaries enable parallel writes across nodes; replicas improve read throughput and fault tolerance but double storage. Recommended shard size is 10-50 GB -- too many small shards increase cluster state overhead and memory pressure.

### High cardinality

OpenSearch handles high cardinality differently for **values** (many unique values in a field) vs **keys** (many unique field names).

**High cardinality values** (e.g. `trace_id`, `user_id` with millions of unique values) -- filtering/search remains fast (O(log n) in the inverted index). However, aggregations (`terms`, `cardinality`) degrade past ~1M unique values because [global ordinals](https://docs.opensearch.org/latest/field-types/supported-field-types/keyword/) are loaded into heap (can consume hundreds of MB per field per shard).

**High cardinality keys** (e.g. dynamic span attributes creating thousands of unique field names) -- this causes [mapping explosion](https://docs.opensearch.org/latest/mappings/mapping-explosion/). Every unique field name creates a mapping entry stored in cluster state on **every node's heap**. The default limit is 1,000 fields per index (`index.mapping.total_fields.limit`). Beyond ~10,000 fields, cluster state consumes GBs of heap.

| Dimension | OK | Warning | Danger |
|---|---|---|---|
| Unique field names per index | <1,000 | 1,000-10,000 | >10,000 |
| Unique values per field (filtering) | <100M | Rarely problematic | -- |
| Unique values per field (aggregations) | <1M | 1M-10M | >10M |

**Mitigations:**
- [`flat_object`](https://docs.opensearch.org/latest/field-types/supported-field-types/flat-object/) field type for dynamic attributes (stores all key-value pairs as a single mapping entry) -- critical for trace span attributes
- Explicit mappings with `index: false` on fields you don't search
- `keyword` instead of `text` to avoid analyzer overhead
- Disable `doc_values` on fields you never sort/aggregate

For comparison, Loki limits label cardinality aggressively (<100K active streams). OpenSearch tolerates high-cardinality values much better but has a similar problem with high-cardinality keys at a higher threshold.

### Multi-tenancy

OpenSearch provides multi-tenancy through the [security plugin](https://docs.opensearch.org/latest/security/multi-tenancy/tenant-index/) at two levels:

- **Dashboards tenancy** -- global, private, and custom tenants control which saved objects (dashboards, visualizations, index patterns) users see. This is UI-level isolation only, not data isolation.
- **Data isolation** requires one of three models, all configured manually:
  - **Silo model** -- separate index per tenant (e.g. `otel-v1-logs-tenant-a-*`, `otel-v1-logs-tenant-b-*`). Full isolation, but requires configuring Data Prepper to route documents to tenant-specific indices (e.g. via the routing processor using a field like `k8s.namespace.name`). A single Data Prepper deployment can handle this.
  - **Pool model** -- shared index with [document-level security (DLS)](https://docs.opensearch.org/latest/security/access-control/document-level-security/) rules filtering documents by a tenant field. Simpler operationally but requires every document to carry a tenant identifier.
  - **Hybrid** -- combination of silo for large tenants and pool for smaller ones.

Unlike LokiStack/TempoStack which use an external gateway proxy (similar to [Observatorium API](https://github.com/observatorium/api/)) for authentication and tenant enforcement, OpenSearch internalizes this via the Security plugin -- no separate proxy component exists or is needed. The Security plugin supports [OIDC natively](https://docs.opensearch.org/latest/security/authentication-backends/openid-connect/): it validates JWTs, maps OIDC claims to OpenSearch roles/tenants via `roles_key` and `subject_key`, and enforces index-level and document-level permissions. OpenSearch Dashboards also supports [OIDC sign-in](https://docs.opensearch.org/latest/security/configuration/multi-auth/) with multi-tenancy.

However, there is no automatic integration with OpenShift OAuth -- mapping OpenShift users/groups to OpenSearch roles and tenants requires manual `roles_mapping.yml` configuration and is not managed by the operator. On OpenShift, a common pattern is to add an [oauth-proxy](https://github.com/openshift/oauth-proxy) sidecar in front of Dashboards for SSO, but this only handles authentication, not tenant-scoped data isolation.

## Tracing (replacing Tempo)

| Capability | Tempo | OpenSearch |
|---|---|---|
| **Query model** | Trace ID lookup + limited tag search (vParquet) | Full inverted index on all span fields, arbitrary boolean queries, aggregations |
| **Search by duration/percentiles** | Limited (TraceQL) | Native aggregations and percentile queries |
| **Service map** | Grafana plugin (client-side) | Server-side computation via Data Prepper |
| **Visualization** | Grafana (Tempo data source) | [Trace Analytics plugin](https://docs.opensearch.org/latest/observing-your-data/trace/ta-dashboards/) -- service maps, latency histograms, waterfall diagrams |
| **Storage** | Object storage (S3/MinIO) natively | Block storage (SSD PVCs), or remote store with S3 (see below) |
| **Multi-tenancy** | Gateway + OIDC, tenant-scoped RBAC | Security plugin: silo (index-per-tenant), pool (document-level security), or hybrid |

OpenSearch provides stronger ad-hoc trace search. Tempo is more storage-efficient for high-volume write-heavy workloads.

## Logging (replacing Loki)

| Capability | Loki | OpenSearch |
|---|---|---|
| **Indexing** | Labels only (pod, namespace, container); brute-force scans log content | Full-text inverted index on every field |
| **Full-text search** | Slow for grep-style queries across large volumes | Fast arbitrary text search |
| **Query language** | LogQL | OpenSearch DSL, SQL, PPL |
| **Lifecycle management** | Simple retention config | [ISM policies](https://docs.opensearch.org/latest/im-plugin/ism/index/) -- rollover, hot/warm/cold tiers, force merge, deletion |
| **Storage** | Object storage (S3/MinIO) natively | Block storage (SSD PVCs), or remote store with S3 (see below) |

OpenSearch is significantly better for "needle in haystack" log queries. Loki is adequate when queries can be narrowed by labels first and uses far less storage.

## Storage Architecture

OpenSearch supports three storage models, each with different cost/performance trade-offs:

| Model | Storage | Local disk role | Query latency | Best for |
|---|---|---|---|---|
| **All-hot (traditional)** | SSD PVCs only | Primary store | Lowest | Small deployments, latency-sensitive |
| **Hot-warm-cold** | SSD (hot) + HDD (warm) + S3 snapshots (cold) | Primary store per tier | Low (hot/warm), high (cold) | Cost optimization with tiered retention |
| **Remote store** | S3/MinIO as primary | Write buffer + LRU cache | Low (cached), higher (non-cached) | Large scale, object-storage-first |

**Loki and Tempo** use object storage (S3/MinIO) as their **only** primary store from the start -- all data is written to S3 immediately, local disk is used only for WAL/cache. This is why they need so little RAM and local disk.

**OpenSearch traditionally** requires block storage (SSD PVCs) as its primary store, with data replicated across nodes. This is why it needs significantly more RAM (filesystem cache) and local disk. The hot-warm-cold model reduces cost by using cheaper storage for older data but still keeps everything on local disk across tiers.

**OpenSearch with remote store** (2.10+) closes this gap by adopting the same pattern as Loki/Tempo -- all segments and translog are pushed to S3 immediately, local disk is only a cache. This significantly reduces local storage requirements and allows replicas to pull from S3 instead of replicating from the primary. However, OpenSearch still builds a full inverted index on every field (unlike Loki/Tempo's minimal indexing), so the data stored on S3 is larger and queries on non-cached data download larger segments.

The most common production pattern is **hot-warm with ISM policies** (7-14 days hot, rest warm, delete after 30-90 days). Remote store is AWS's recommended path for new managed deployments but adoption on self-managed clusters is still early.

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

The tables below use the 1:30 ratio for all data, which represents an **all-hot architecture** (worst case). A **hot-warm-cold architecture** can significantly reduce costs by keeping only recent data (e.g. 2-3 days) on expensive hot nodes and migrating older data to cheaper tiers:

| Tier | Memory:data ratio | Storage type | Use case |
|------|-------------------|-------------|----------|
| **Hot** | 1:30 | SSD | Recent data, active indexing + frequent queries |
| **Warm** | 1:160 | HDD or cheaper SSD | Older data, read-only, infrequent queries |
| **Cold** | minimal | Object storage (S3) via searchable snapshots | Archive, rare queries, high latency acceptable |

Example for 500 GB/day with 15-day retention using hot-warm: 2 days hot (2,500 GB at 1:30 = 83 Gi) + 13 days warm (16,250 GB at 1:160 = 102 Gi) = **185 Gi total** vs 625 Gi all-hot. This is a ~3.4x reduction in RAM but adds operational complexity ([ISM policies](https://docs.opensearch.org/latest/im-plugin/ism/index/) to automate index migration between tiers) and slower queries on older data.

**CPU (data nodes):** Driven by indexing throughput and search concurrency. Each vCPU handles roughly 5-10 MB/s of indexing throughput depending on mapping complexity. At 500 GB/day (~5.8 MB/s average, but peak can be 2-3x), 10 nodes with 8 CPUs each provides headroom for burst traffic and concurrent search queries. At 2 TB/day (~23 MB/s average), 40 nodes x 8 CPUs handles ~16 MB/s indexing capacity per node plus search load.

**Dedicated master nodes:** Recommended for all production clusters ([AWS best practices](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/managedomains-dedicatedmasternodes.html)). Masters manage cluster state (shard allocation, index metadata, node membership) and do not hold data. Combining master and data roles on the same nodes is a common cost optimization for very small clusters (3 nodes), but is not recommended for production because data node operations -- heavy indexing, long GC pauses, expensive queries -- can starve the master role and cause cluster instability (missed heartbeats, shard allocation delays, split-brain risk). Sized at 2-4 CPU / 8-16 GB depending on cluster size.

**Data Prepper:** Ingestion pipeline that receives OTLP data and writes to OpenSearch. Scales at ~1 instance (2 CPU, 4-8 GB) per 50 GB/day of ingestion. For logs, Data Prepper is essentially passthrough -- it receives log documents via OTLP and writes them to OpenSearch with minimal buffering. For traces, Data Prepper runs three chained pipelines:

- **`entry-pipeline`** -- accepts OTLP spans from the OTel Collector and fans out to the other two pipelines. No processing itself.
- **`raw-trace-pipeline`** -- runs the `otel_traces` processor which performs stateful trace-group enrichment: buffers spans by trace ID, identifies the root span, and copies the root span's operation name into a `traceGroup` field on every span in the trace. This enables filtering/aggregating spans by the top-level operation that initiated the trace (e.g. "show all spans triggered by `POST /api/checkout`"). Writes to `otel-v1-apm-span-*` index. **Required** -- without it spans don't reach OpenSearch.
- **`service-map-pipeline`** -- runs the `service_map` processor which aggregates parent-child relationships across spans to build a service dependency graph. Writes to `otel-v1-apm-service-map` index. **Optional** -- can be disabled if the Service Map visualization in OpenSearch Dashboards is not needed.

The raw-trace and service-map pipelines must **buffer spans in memory** for a configurable window (default 30 seconds). This span buffering is why trace instances need more RAM (8 Gi vs 4 Gi).

Data Prepper can also be **bypassed entirely** by using the OTel Collector's `opensearch` exporter to write spans directly to OpenSearch. This gives raw span storage and basic search, but loses trace-group enrichment (`traceGroup` field not populated, so filtering by root operation breaks) and service map generation. The Trace Analytics dashboards in OpenSearch will be partially broken without Data Prepper.

#### Reducing RAM requirements

The tables below use the standard 1:30 memory:data ratio, which assumes all fields are indexed and all data is on local disk. Several techniques can reduce RAM significantly:

**Index mapping optimization** -- skip indexing fields you never search. Setting `index: false` on fields (e.g. raw message bodies, debug metadata) removes them from the inverted index, reducing heap by ~10-30%. Setting `enabled: false` on sub-objects skips parsing entirely. For traces with high-cardinality dynamic attributes, the [`flat_object`](https://docs.opensearch.org/latest/field-types/supported-field-types/flat-object/) field type (OpenSearch 2.7+) stores all dynamic key-value pairs as a single field instead of creating one field per key -- critical for reducing field mapping overhead.

**Codec compression** -- using `best_compression` (zstd, OpenSearch 2.9+) reduces stored data ~30-40% vs default LZ4. Since RAM scales with stored data, this proportionally reduces memory needs.

**Shard consolidation** -- each shard costs ~10-50 MB of heap overhead for segment metadata. Too many small shards (e.g. daily indices with low volume) waste heap. Target 10-50 GB per shard and force-merge old read-only indices to 1 segment per shard.

**Remote-backed storage** -- OpenSearch 2.10+ supports [`remote_store`](https://docs.opensearch.org/latest/tuning-your-cluster/availability-and-recovery/remote-store/index/) with S3-compatible backends (MinIO, Ceph RGW, AWS S3) natively via the pre-installed `repository-s3` plugin. Unlike the hot-warm-cold architecture which migrates old data after some time, remote store pushes **all data to S3 immediately** -- every segment and translog entry is uploaded as soon as it's flushed. Local disk serves only as a write-ahead buffer and LRU cache:

- **Writes**: primary node flushes segments locally, then immediately uploads to S3
- **Replicas**: pull segments from S3 instead of copying from the primary over the network
- **Queries on cached segments**: work normally via memory-mapped files, no extra latency
- **Queries on non-cached segments**: segments are downloaded from S3 to local disk on demand, then memory-mapped and queried. The first query on cold data pays the S3 download cost; subsequent queries hit the local cache
- **Cache eviction**: LRU -- when local disk fills up, least recently used segments are evicted. The `diskSize` in the CR controls cache size: larger = fewer S3 fetches = faster queries

This is architecturally closer to how Loki and Tempo work -- they also write everything to object storage immediately with only a local WAL/cache. The key difference is that OpenSearch downloads full index segments (inverted index + stored fields + doc values) which are larger than Loki/Tempo's compressed chunks.

The combination of selective field indexing + zstd compression + remote-backed storage can bring the effective ratio closer to 1:100, significantly narrowing the gap with Loki/Tempo. The trade-off is reduced query flexibility (unindexed fields can't be searched) and higher query latency on non-cached data.

#### All-hot architecture (15 days retention, all data on SSD)

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

#### Alternative: hot-warm architecture (3 days hot + 12 days warm)

Hot nodes (1:30 ratio, SSD) hold the most recent 3 days for active indexing and frequent queries. Warm nodes (1:160 ratio, HDD) hold the remaining 12 days as read-only data with slower query performance. [ISM policies](https://docs.opensearch.org/latest/im-plugin/ism/index/) automate index migration between tiers.

| | pico (50 GB/day) | extra-small (100 GB/day) | small (500 GB/day) | medium (2 TB/day) |
|---|---|---|---|---|
| **Hot stored (3d)** | 375 GB | 750 GB | 3.75 TB | 15 TB |
| **Hot RAM (1:30)** | 12.5 Gi | 25 Gi | 125 Gi | 500 Gi |
| **Hot nodes** | 3x (2 CPU, 8 GB, SSD) | 3x (4 CPU, 16 GB, SSD) | 3x (8 CPU, 64 GB, SSD) | 8x (8 CPU, 64 GB, SSD) |
| **Warm stored (12d)** | 1.5 TB | 3 TB | 15 TB | 60 TB |
| **Warm RAM (1:160)** | 9.4 Gi | 18.75 Gi | 93.75 Gi | 375 Gi |
| **Warm nodes** | 3x (2 CPU, 8 GB, HDD) | 3x (2 CPU, 8 GB, HDD) | 3x (4 CPU, 32 GB, HDD) | 6x (4 CPU, 64 GB, HDD) |
| **Dedicated masters** | 3x (2 CPU, 8 GB) | 3x (2 CPU, 8 GB) | 3x (2 CPU, 8 GB) | 3x (4 CPU, 16 GB) |
| **Data Prepper** | 1x (2 CPU, 4-8 GB) | 2x (2 CPU, 4-8 GB) | 4x (2 CPU, 8 GB) | 8x (2 CPU, 8 GB) |
| **Total CPU** | 20 vCPUs | 28 vCPUs | 50 vCPUs | 116 vCPUs |
| **Total memory** | 76-80 Gi | 104-112 Gi | 344 Gi | 1,008 Gi |
| **SSD disk** | 375 GB | 750 GB | 3.75 TB | 15 TB |
| **HDD disk** | 1.5 TB | 3 TB | 15 TB | 60 TB |

Compared to all-hot, hot-warm reduces total RAM by **~40-60%** and replaces most SSD with cheaper HDD. The trade-off is slower queries on data older than 3 days and added operational complexity from ISM index lifecycle policies.

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

OpenSearch can correlate logs and traces by indexing the `trace_id` field in both log and span documents, then joining in Dashboards. However, this only works if OpenSearch receives **both** logs and traces. If it replaces only one backend, there is no built-in cross-linking between OpenSearch Dashboards and Grafana -- you would have to manually copy the trace ID and search in both UIs separately. Using OpenSearch for both data types doubles the resource requirements shown above.

In the Grafana stack (current setup), Tempo and Loki provide native cross-linking via data source configuration -- clicking a trace ID in Loki jumps to the trace in Tempo and vice versa, with zero custom indexing.

## Verdict

| | Loki + Tempo (current) | OpenSearch |
|---|---|---|
| **Search power** | Label-based (Loki), TraceQL (Tempo) | Full-text search on everything |
| **Resource cost** | Low (object-storage-native) | High (JVM + block storage) |
| **Operational complexity** | Managed by Red Hat operators | JVM tuning, shard management, capacity planning |
| **Strategic direction** | Aligned with Red Hat (LGTM stack) | Goes against Red Hat's direction |
| **Single backend** | Two separate systems | One system for logs + traces |
| **Alerting** | Grafana alerting | Built-in alerting + anomaly detection |

**OpenSearch makes sense when:** full-text search across logs and traces is a hard requirement, the team has Elasticsearch/OpenSearch expertise, and Red Hat support is not needed.

**Loki + Tempo is better when:** cost efficiency, Red Hat support, and alignment with the OpenShift platform strategy matter more than raw search capability.

## Deploy

1. Install the opensearch-k8s-operator via Helm (not available in OperatorHub):

```bash
./opensearch/00-install-operator.sh
```

2. Set `vm.max_map_count` on worker nodes (triggers a rolling reboot of workers):

```bash
kubectl apply -f opensearch/00-prerequisites.yaml
```

3. Deploy OpenSearch cluster (includes ISM retention policies) + Data Prepper:

```bash
kubectl apply -f opensearch/01-deploy-opensearch.yaml
kubectl apply -f opensearch/02-deploy-data-prepper.yaml
```

### Forward data from OTel Collector

Add to the OTel Collector config to send traces and logs to Data Prepper:

```yaml
exporters:
  otlp/opensearch:
    endpoint: data-prepper.opensearch.svc.cluster.local:21890
    tls:
      insecure: true

service:
  pipelines:
    traces:
      exporters: [otlp/opensearch]
    logs:
      exporters: [otlp/opensearch]
```

### Access OpenSearch Dashboards

```bash
oc port-forward svc/opensearch-dashboards 5601:5601 -n opensearch
# Open http://localhost:5601 -- login with admin/admin
```

## References
* [LokiStack sizing -- Red Hat OpenShift Logging 6.5](https://docs.redhat.com/en/documentation/red_hat_openshift_logging/6.5/html/configuring_logging/configuring-lokistack-storage#loki-sizing_configuring-the-log-store)
* [TempoStack sizing -- Red Hat Distributed Tracing](https://107838--ocpdocs-pr.netlify.app/openshift-enterprise/latest/observability/distr_tracing/distr-tracing-tempo-configuring.html#distr-tracing-tempo-config-size_distr-tracing-tempo-configuring)
* [AWS OpenSearch sizing domains](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/sizing-domains.html) -- 1:30 memory:data ratio for hot tier
* [Elastic: benchmarking and sizing for logs and metrics](https://www.elastic.co/blog/benchmarking-and-sizing-your-elasticsearch-cluster-for-logs-and-metrics)
* [Elastic: sizing hot-warm architectures](https://www.elastic.co/blog/sizing-hot-warm-architectures-for-logging-and-metrics-in-the-elasticsearch-service-on-elastic-cloud)
* [Opster: OpenSearch memory usage and capacity planning](https://opster.com/guides/opensearch/opensearch-capacity-planning/memory-usage/)
* [Grafana Loki vs Elasticsearch](https://medium.com/engenharia-arquivei/grafana-loki-our-journey-on-replacing-elastic-search-and-adopting-a-new-logging-solution-at-f65aec407e47)
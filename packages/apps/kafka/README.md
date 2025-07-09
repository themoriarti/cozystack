# Managed Kafka Service

## Parameters

### Common parameters

| Name                        | Description                                                                                                                            | Value   |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `external`                  | Enable external access from outside the cluster                                                                                        | `false` |
| `kafka.size`                | Persistent Volume size for Kafka                                                                                                       | `10Gi`  |
| `kafka.replicas`            | Number of Kafka replicas                                                                                                               | `3`     |
| `kafka.storageClass`        | StorageClass used to store the Kafka data                                                                                              | `""`    |
| `zookeeper.size`            | Persistent Volume size for ZooKeeper                                                                                                   | `5Gi`   |
| `zookeeper.replicas`        | Number of ZooKeeper replicas                                                                                                           | `3`     |
| `zookeeper.storageClass`    | StorageClass used to store the ZooKeeper data                                                                                          | `""`    |
| `kafka.resources`           | Explicit CPU and memory configuration for each Kafka replica. When left empty, the preset defined in `resourcesPreset` is applied.     | `{}`    |
| `kafka.resourcesPreset`     | Default sizing preset used when `resources` is omitted. Allowed values: none, nano, micro, small, medium, large, xlarge, 2xlarge.      | `small` |
| `zookeeper.resources`       | Explicit CPU and memory configuration for each Zookeeper replica. When left empty, the preset defined in `resourcesPreset` is applied. | `{}`    |
| `zookeeper.resourcesPreset` | Default sizing preset used when `resources` is omitted. Allowed values: none, nano, micro, small, medium, large, xlarge, 2xlarge.      | `small` |

### Configuration parameters

| Name     | Description          | Value |
| -------- | -------------------- | ----- |
| `topics` | Topics configuration | `[]`  |

## Parameter examples and reference

### resources and resourcesPreset

`resources` sets explicit CPU and memory configurations for each replica.
When left empty, the preset defined in `resourcesPreset` is applied.

```yaml
resources:
  cpu: 4000m
  memory: 4Gi
```

`resourcesPreset` sets named CPU and memory configurations for each replica.
This setting is ignored if the corresponding `resources` value is set.

| Preset name | CPU    | memory  |
|-------------|--------|---------|
| `nano`      | `250m` | `128Mi` |
| `micro`     | `500m` | `256Mi` |
| `small`     | `1`    | `512Mi` |
| `medium`    | `1`    | `1Gi`   |
| `large`     | `2`    | `2Gi`   |
| `xlarge`    | `4`    | `4Gi`   |
| `2xlarge`   | `8`    | `8Gi`   |

### topics

```yaml
topics:
  - name: Results
    partitions: 1
    replicas: 3
    config:
      min.insync.replicas: 2
  - name: Orders
    config:
      cleanup.policy: compact
      segment.ms: 3600000
      max.compaction.lag.ms: 5400000
      min.insync.replicas: 2
    partitions: 1
    replicas: 3
```

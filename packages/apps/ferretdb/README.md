# Managed FerretDB Service

FerretDB is an open source MongoDB alternative.
It translates MongoDB wire protocol queries to SQL and can be used as a direct replacement for MongoDB 5.0+.
Internally, FerretDB service is backed by Postgres.

## Parameters

### Common parameters

| Name                     | Description                                                                                                                 | Value   |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------- | ------- |
| `external`               | Enable external access from outside the cluster                                                                             | `false` |
| `size`                   | Persistent Volume size                                                                                                      | `10Gi`  |
| `replicas`               | Number of replicas                                                                                                          | `2`     |
| `storageClass`           | StorageClass used to store the data                                                                                         | `""`    |
| `quorum.minSyncReplicas` | Minimum number of synchronous replicas that must acknowledge a transaction before it is considered committed                | `0`     |
| `quorum.maxSyncReplicas` | Maximum number of synchronous replicas that can acknowledge a transaction (must be lower than the total number of replicas) | `0`     |

### Configuration parameters

| Name    | Description         | Value |
| ------- | ------------------- | ----- |
| `users` | Users configuration | `{}`  |

### Backup parameters

| Name                     | Description                                                | Value                               |
| ------------------------ | ---------------------------------------------------------- | ----------------------------------- |
| `backup.enabled`         | Enable regular backups                                     | `false`                             |
| `backup.schedule`        | Cron schedule for automated backups                        | `0 2 * * * *`                       |
| `backup.retentionPolicy` | Retention policy                                           | `30d`                               |
| `backup.destinationPath` | Path to store the backup (i.e. s3://bucket/path/to/folder) | `s3://bucket/path/to/folder/`       |
| `backup.endpointURL`     | S3 Endpoint used to upload data to the cloud               | `http://minio-gateway-service:9000` |
| `backup.s3AccessKey`     | Access key for S3, used for authentication                 | `oobaiRus9pah8PhohL1ThaeTa4UVa7gu`  |
| `backup.s3SecretKey`     | Secret key for S3, used for authentication                 | `ju3eum4dekeich9ahM1te8waeGai0oog`  |

### Bootstrap parameters

| Name                     | Description                                                                                                                           | Value   |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `bootstrap.enabled`      | Restore database cluster from a backup                                                                                                | `false` |
| `bootstrap.recoveryTime` | Timestamp (PITR) up to which recovery will proceed, expressed in RFC 3339 format. If left empty, will restore latest                  | `""`    |
| `bootstrap.oldName`      | Name of database cluster before deleting                                                                                              | `""`    |
| `resources`              | Explicit CPU and memory configuration for each FerretDB replica. When left empty, the preset defined in `resourcesPreset` is applied. | `{}`    |
| `resourcesPreset`        | Default sizing preset used when `resources` is omitted. Allowed values: none, nano, micro, small, medium, large, xlarge, 2xlarge.     | `micro` |



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

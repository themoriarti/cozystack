## Managed MariaDB Service

The Managed MariaDB Service offers a powerful and widely used relational database solution.
This service allows you to create and manage a replicated MariaDB cluster seamlessly.

## Deployment Details

This managed service is controlled by mariadb-operator, ensuring efficient management and seamless operation.

- Docs: https://mariadb.com/kb/en/documentation/
- GitHub: https://github.com/mariadb-operator/mariadb-operator

## HowTos

### How to switch master/slave replica

```
kubectl edit mariadb <instnace>
```
update:

```
spec:
  replication:
    primary:
      podIndex: 1
```

check status:

```
NAME        READY   STATUS    PRIMARY POD   AGE
<instance>  True    Running   app-db1-1     41d
```

### How to restore backup:

find snapshot:
```
restic -r s3:s3.example.org/mariadb-backups/database_name snapshots
```


restore:
```
restic -r s3:s3.example.org/mariadb-backups/database_name restore latest --target /tmp/
```

more details:
- https://blog.aenix.io/restic-effective-backup-from-stdin-4bc1e8f083c1

### Known issues

- **Replication can't not be finished with various errors**
- **Replication can't be finised in case if binlog purged**
  Until mariadbbackup is not used to bootstrap a node by mariadb-operator (this feature is not inmplemented yet), follow these manual steps to fix it:
  https://github.com/mariadb-operator/mariadb-operator/issues/141#issuecomment-1804760231

- **Corrupted indicies**
  Sometimes some indecies can be corrupted on master replica, you can recover them from slave:

  ```
  mysqldump -h <slave> -P 3306 -u<user> -p<password> --column-statistics=0 <database> <table> ~/tmp/fix-table.sql
  mysql -h <master> -P 3306 -u<user> -p<password> <database> < ~/tmp/fix-table.sql
  ```

## Parameters

### Common parameters

| Name           | Description                                     | Value   |
| -------------- | ----------------------------------------------- | ------- |
| `external`     | Enable external access from outside the cluster | `false` |
| `size`         | Persistent Volume size                          | `10Gi`  |
| `replicas`     | Number of MariaDB replicas                      | `2`     |
| `storageClass` | StorageClass used to store the data             | `""`    |

### Configuration parameters

| Name        | Description             | Value |
| ----------- | ----------------------- | ----- |
| `users`     | Users configuration     | `{}`  |
| `databases` | Databases configuration | `{}`  |

### Backup parameters

| Name                     | Description                                                                                                                          | Value                                                  |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------ |
| `backup.enabled`         | Enable periodic backups                                                                                                              | `false`                                                |
| `backup.s3Region`        | The AWS S3 region where backups are stored                                                                                           | `us-east-1`                                            |
| `backup.s3Bucket`        | The S3 bucket used for storing backups                                                                                               | `s3.example.org/postgres-backups`                      |
| `backup.schedule`        | Cron schedule for automated backups                                                                                                  | `0 2 * * *`                                            |
| `backup.cleanupStrategy` | The strategy for cleaning up old backups                                                                                             | `--keep-last=3 --keep-daily=3 --keep-within-weekly=1m` |
| `backup.s3AccessKey`     | The access key for S3, used for authentication                                                                                       | `oobaiRus9pah8PhohL1ThaeTa4UVa7gu`                     |
| `backup.s3SecretKey`     | The secret key for S3, used for authentication                                                                                       | `ju3eum4dekeich9ahM1te8waeGai0oog`                     |
| `backup.resticPassword`  | The password for Restic backup encryption                                                                                            | `ChaXoveekoh6eigh4siesheeda2quai0`                     |
| `resources`              | Explicit CPU and memory configuration for each MariaDB replica. When left empty, the preset defined in `resourcesPreset` is applied. | `{}`                                                   |
| `resourcesPreset`        | Default sizing preset used when `resources` is omitted. Allowed values: none, nano, micro, small, medium, large, xlarge, 2xlarge.    | `nano`                                                 |

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

### users

```yaml
users:
  user1:
    maxUserConnections: 1000
    password: hackme
  user2:
    maxUserConnections: 1000
    password: hackme
```


### databases

```yaml
databases:
  myapp1:
    roles:
      admin:
      - user1
      readonly:
      - user2
```

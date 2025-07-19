# Managed NATS Service

## Parameters

### Common parameters

| Name                | Description                                                                                            | Value    |
| ------------------- | ------------------------------------------------------------------------------------------------------ | -------- |
| `host`              | The hostname used to access the SeaweedFS externally (defaults to 's3' subdomain for the tenant host). | `""`     |
| `topology`          | The topology of the SeaweedFS cluster. (allowed values: Simple, MultiZone)                             | `Simple` |
| `replicationFactor` | The number of replicas for each volume in the SeaweedFS cluster.                                       | `2`      |
| `replicas`          | Persistent Volume size for SeaweedFS                                                                   | `2`      |
| `size`              | Persistent Volume size                                                                                 | `10Gi`   |
| `storageClass`      | StorageClass used to store the data                                                                    | `""`     |
| `zones`             | A map of zones for MultiZone topology. Each zone can have its own number of replicas and size.         | `{}`     |

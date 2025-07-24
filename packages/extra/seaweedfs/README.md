# Managed NATS Service

## Parameters

### Common parameters

| Name                | Description                                                                                                              | Value           |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------ | --------------- |
| `host`              | The hostname used to access the SeaweedFS externally (defaults to 's3' subdomain for the tenant host).                   | `""`            |
| `topology`          | The topology of the SeaweedFS cluster. (allowed values: Simple, MultiZone, Client)                                       | `Simple`        |
| `replicationFactor` | The number of replicas for each volume in the SeaweedFS cluster.                                                         | `2`             |
| `replicas`          | Persistent Volume size for SeaweedFS                                                                                     | `2`             |
| `size`              | Persistent Volume size                                                                                                   | `10Gi`          |
| `storageClass`      | StorageClass used to store the data                                                                                      | `""`            |
| `zones`             | A map of zones for MultiZone topology. Each zone can have its own number of replicas and size.                           | `{}`            |
| `filer.external`    | Enable external access to the SeaweedFS filer from outside the cluster. Use this when `topology` is not set to `Client`. | `false`         |
| `remoteEndpoint`    | The endpoint of the remote filer GRPC service. Used when `topology` is set to `Client`.                                  | `1.2.3.4:18888` |

# Etcd-cluster

## Parameters

### Common parameters

| Name               | Description                         | Value |
| ------------------ | ----------------------------------- | ----- |
| `size`             | Persistent Volume size              | `4Gi` |
| `storageClass`     | StorageClass used to store the data | `""`  |
| `replicas`         | Number of etcd replicas             | `3`   |
| `resources.cpu`    | The number of CPU cores allocated   | `4`   |
| `resources.memory` | The amount of memory allocated      | `1Gi` |

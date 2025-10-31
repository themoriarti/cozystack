# VPC

VPC offers a subset of dedicated subnets with networking services related to it.
As the service evolves, it will provide more ways to isolate your workloads.

## Service details

The service utilizes kube-ovn VPC and Subnet resources, which use ovn logical routers and logical switches under the hood.
Currently every workload will have a connection to a default management network which will also have a default gateway, and the majority of traffic will be going through it.
VPC subnets are for now an additional dedicated networking spaces.

A VM or a pod may be connected to multiple secondary Subnets at once.
Each secondary connection will be represented as an additional network interface.

## Deployment notes

VPC name must be unique within a tenant.
Subnet name and ip address range must be unique within a VPC.
Subnet ip address space must not overlap with the default management network ip address range, subsets of 172.16.0.0/12 are recommended.
Currently there are no fail-safe checks, however they are planned for the future.

Different VPCs may have subnets with ovelapping ip address ranges.

## Parameters

### Common parameters

| Name                 | Description                      | Type                | Value   |
| -------------------- | -------------------------------- | ------------------- | ------- |
| `subnets`            | Subnets of a VPC                 | `map[string]object` | `{...}` |
| `subnets[name].cidr` | Subnet CIDR, e.g. 192.168.0.0/24 | `cidr`              | `{}`    |


## Examples
```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: VirtualPrivateCloud
metadata:
  name: vpc00
spec:
  subnets:
    sub00:
      cidr: 172.16.0.0/24
    sub01:
      cidr: 172.16.1.0/24
    sub02:
      cidr: 172.16.2.0/24
```

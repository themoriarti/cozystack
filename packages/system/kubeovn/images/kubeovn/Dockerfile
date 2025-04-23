ARG VERSION=v1.13.10
FROM kubeovn/kube-ovn:${VERSION}

# Fix https://github.com/kubeovn/kube-ovn/issues/4526
RUN setcap CAP_NET_ADMIN,CAP_NET_BIND_SERVICE,CAP_SYS_ADMIN+eip /usr/lib/openvswitch-switch/ovs-vswitchd \
 && setcap CAP_NET_ADMIN,CAP_NET_BIND_SERVICE,CAP_SYS_ADMIN+eip /usr/sbin/xtables-legacy-multi \
 && setcap CAP_NET_ADMIN,CAP_NET_BIND_SERVICE,CAP_SYS_ADMIN+eip /usr/sbin/xtables-nft-multi \
 && setcap CAP_NET_ADMIN,CAP_NET_RAW,CAP_NET_BIND_SERVICE,CAP_SYS_ADMIN+eip /usr/sbin/ipset \
 && setcap CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_ADMIN+eip /usr/bin/ip

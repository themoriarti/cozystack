{{- /*
  The worker TalosConfigTemplate, kept in one place.

  The talos-reconcile Job is what applies this template: three of its inputs
  (the apiserver Service address, the Talos CA and the Kamaji-issued CA) only
  exist after the parent release has applied, so the spec rendered here still
  carries ${...} placeholders that the Job's heredoc fills in at runtime.
*/}}

{{- /* kubernetes-nodes.talosConfigContext fills .out — a deepCopy of the root
       context the caller owns — with every value the TalosConfigTemplate spec
       reads. Called as (dict "root" $ "out" $ctx); it emits nothing. */}}
{{- define "kubernetes-nodes.talosConfigContext" -}}
{{- $root := .root }}
{{- $out := .out }}
{{- $kubeletVersion := include "kubernetes.versionMap" $root | trim }}
{{- $podCIDR := "10.243.0.0/16" }}
{{- $serviceCIDR := "10.95.0.0/16" }}
{{- $dnsDomain := include "kubernetes.tenantClusterDomain" $root }}
{{- $mgmtClusterDomain := (index ($root.Values._cluster | default dict) "cluster-domain") | default "cozy.local" }}
{{- /* kernelModules carries no entry in values.yaml, so the key is absent here
       unless the operator set it, and `dict` keeps it nil — which
       kubernetes-nodes.kernelModules reads as "unset", as opposed to an explicit
       empty list that opts the pool out. Defaulting it to `list` here would
       collapse the two. */}}
{{- $group := dict
      "instanceType" $root.Values.instanceType
      "resources" $root.Values.resources
      "gpus" $root.Values.gpus
      "kubelet" $root.Values.kubelet
      "osImage" $root.Values.osImage
      "kernelModules" $root.Values.kernelModules
}}
{{- /* Mirror the kubelet-reservation computation from nodegroup.yaml so the
       worker machineconfig carries the same numbers the MachineDeployment
       validator was happy with. */}}
{{- $instanceType := dict }}
{{- if $group.instanceType }}
{{-   $instanceType = lookup "instancetype.kubevirt.io/v1beta1" "VirtualMachineClusterInstancetype" "" $group.instanceType }}
{{-   $instanceType = $instanceType | default dict }}
{{- end }}
{{- $effectiveMemory := "" }}
{{- if and $group.resources $group.resources.memory }}
{{-   $effectiveMemory = $group.resources.memory | toString }}
{{- else if and $instanceType $instanceType.spec $instanceType.spec.memory $instanceType.spec.memory.guest }}
{{-   $effectiveMemory = $instanceType.spec.memory.guest | toString }}
{{- end }}
{{- $effectiveCpu := "" }}
{{- if and $group.resources $group.resources.cpu }}
{{-   $effectiveCpu = $group.resources.cpu | toString }}
{{- else if and $instanceType $instanceType.spec $instanceType.spec.cpu $instanceType.spec.cpu.guest }}
{{-   $effectiveCpu = $instanceType.spec.cpu.guest | toString }}
{{- end }}
{{- $autoReservedMi := 256 }}
{{- if $effectiveMemory }}
{{-   $effectiveMemMi := divf (include "cozy-lib.resources.toFloat" $effectiveMemory | float64) 1048576.0 | int }}
{{-   $fivePercentMi := mulf ($effectiveMemMi | float64) 0.05 | int }}
{{-   $autoReservedMi = min (max $fivePercentMi 256) 1024 }}
{{- end }}
{{- $autoReservedMillicores := 50 }}
{{- if $effectiveCpu }}
{{-   $effectiveCpuMillicores := include "kubernetes.cpuToMillicores" $effectiveCpu | int }}
{{-   $fivePercentMillis := mulf ($effectiveCpuMillicores | float64) 0.05 | int }}
{{-   $autoReservedMillicores = min (max $fivePercentMillis 50) 500 }}
{{- end }}
{{- $kubeletOverride := $group.kubelet | default dict }}
{{- $systemReservedMemory := $kubeletOverride.systemReservedMemory | default (printf "%dMi" $autoReservedMi) }}
{{- $kubeReservedMemory := $kubeletOverride.kubeReservedMemory | default (printf "%dMi" $autoReservedMi) }}
{{- $systemReservedCpu := $kubeletOverride.systemReservedCpu | default (printf "%dm" $autoReservedMillicores) }}
{{- $kubeReservedCpu := $kubeletOverride.kubeReservedCpu | default (printf "%dm" $autoReservedMillicores) }}
{{- $evictionHardMemory := $kubeletOverride.evictionHardMemory | default "7%" }}
{{- $evictionSoftMemory := $kubeletOverride.evictionSoftMemory | default "10%" }}
{{- /* Resolve this pool's worker image (schematicID, version) from .Values.osImage
       — the same selection templates/nodegroup.yaml uses for the boot disk — so the
       in-guest Talos installer image matches the OS this pool actually booted.
       Defaults to the pool's talos.*; a pool with osImage.builtin / osImage.factory
       pins its own flavor and version so an in-guest upgrade does not flip it back to
       the pool default. */}}
{{- /* Shared with nodegroup.yaml's boot-disk source rather than mirrored here:
       a disk booted from one Talos flavor and an installer pinned to another is
       the silently-broken pairing this chart's support matrix was factored out
       to prevent, and two hand-kept copies of the resolution are how the two
       drift apart. The helper also carries the format checks, so this file no
       longer depends on the other one aborting the shared render first. */}}
{{- $resolvedImage := dict }}
{{- include "kubernetes-nodes.resolveOsImage" (dict
      "osImage" $group.osImage
      "talos" $root.Values.talos
      "out" $resolvedImage
      "groupName" (include "kubernetes-nodes.groupName" $root)) }}
{{- $_ := set $out "group" $group }}
{{- $_ := set $out "groupName" (include "kubernetes-nodes.groupName" $root) }}
{{- $_ := set $out "clusterName" (include "kubernetes-nodes.clusterName" $root) }}
{{- $_ := set $out "kubeletVersion" $kubeletVersion }}
{{- $_ := set $out "talosVersion" $resolvedImage.version }}
{{- $_ := set $out "talosSchematicID" $resolvedImage.schematicID }}
{{- $_ := set $out "podCIDR" $podCIDR }}
{{- $_ := set $out "serviceCIDR" $serviceCIDR }}
{{- $_ := set $out "dnsDomain" $dnsDomain }}
{{- $_ := set $out "mgmtClusterDomain" $mgmtClusterDomain }}
{{- $_ := set $out "systemReservedCpu" $systemReservedCpu }}
{{- $_ := set $out "systemReservedMemory" $systemReservedMemory }}
{{- $_ := set $out "kubeReservedCpu" $kubeReservedCpu }}
{{- $_ := set $out "kubeReservedMemory" $kubeReservedMemory }}
{{- $_ := set $out "evictionHardMemory" $evictionHardMemory }}
{{- $_ := set $out "evictionSoftMemory" $evictionSoftMemory }}
{{- end -}}

{{- /* kubernetes-nodes.talosConfigTemplateSpec renders the TalosConfigTemplate
       `spec:` at column 0 from a context filled by talosConfigContext. The Job
       indents it into its heredoc. */}}
{{- define "kubernetes-nodes.talosConfigTemplateSpec" -}}
spec:
  template:
    spec:
      generateType: none
      talosVersion: "{{ .talosVersion | replace "\\" "\\\\" | replace "$" "\\$" | replace "`" "\\`" }}"
      {{- /* INVARIANT (cozystack/cozystack#3513): the data block below is emitted from the unquoted `TCT_MANIFEST="$(cat <<EOF` heredoc in the talos-reconcile Job's command (templates/talos-reconcile-job.yaml), so it is subject to shell parameter expansion and command substitution at Job runtime. Every tenant-controlled free-form value interpolated into it must therefore be either shell-escaped for backslash, dollar and backtick (as talosVersion here and registryMirrors below are) or render-time pattern-validated to exclude those bytes (as the kubelet reservation fields are in nodegroup.yaml). A new such field added here without one of the two silently reopens command injection into a host-cluster Pod. Note: an asterisk-slash sequence inside this Helm comment closes it early and breaks the render, so the kubelet field names are spelled out here rather than written as globs. This is a Helm comment: it is stripped at render, so its own text never reaches the heredoc. */}}
      data: |
        version: v1alpha1
        persist: true
        machine:
          type: worker
          token: ${TALOS_TOKEN}
          network:
            # Management CoreDNS as the worker's host
            # resolver, plus management cluster search
            # domains so partial names like
            # "linstor-csi-nfs.cozy-linstor.svc" resolve
            # the same way they do on Ubuntu+kubeadm
            # workers in main (which got these via
            # cloud-init/DHCP). Without searchDomains the
            # kubevirt-csi NFS mount fails NXDOMAIN
            # because mount.nfs hands the partial name
            # to the resolver verbatim and management
            # CoreDNS only knows full FQDNs.
            #
            # Tenant in-cluster pods are not affected:
            # dnsPolicy: ClusterFirst routes them through
            # kubelet --cluster-dns (tenant CoreDNS).
            # This block only configures host-side
            # resolution (kubelet mount syscalls, image
            # pulls, pods opted out of cluster DNS).
            nameservers:
              {{- /* A kubevirt worker resolves through the management
                    cluster's CoreDNS over the pod network. A proxmox
                    worker is off-cluster and cannot reach that
                    ClusterIP any more than it can reach the
                    apiserver's, so it carries its own resolvers. */}}
              {{- if eq ($.Values.substrate | default "kubevirt") "proxmox" }}
              {{- range $.Values.proxmox.dnsServers }}
              - {{ . | quote }}
              {{- end }}
              {{- else }}
              - ${COREDNS_IP}
              {{- end }}
            searchDomains:
              - svc.{{ .mgmtClusterDomain }}
              - {{ .mgmtClusterDomain }}
              {{- if ne .mgmtClusterDomain "cluster.local" }}
              - svc.cluster.local
              - cluster.local
              {{- end }}
            extraHostEntries:
              - ip: ${SVC_IP}
                aliases:
                  - ${RELEASE}.${NS}.svc
                  - ${RELEASE}.${NS}.svc.{{ .dnsDomain }}
          ca:
            crt: ${TALOS_CA_B64}
          {{- if .group.gpus }}
          # GPU node-groups: label every node `gpu=on` so
          # HAMi's hami-device-plugin DaemonSet (nodeSelector
          # gpu=on) schedules and advertises nvidia.com/gpu.
          # Without the label the plugin stays at DESIRED=0
          # and no GPUs are exposed to the tenant. Mirrors
          # main's kubeadm config (kubeletExtraArgs node-
          # labels: "gpu=on") so HAMi behaviour is identical
          # before and after the Talos worker rollover.
          nodeLabels:
            gpu: "on"
          {{- end }}
          {{- /* Emitted only when the pool resolves to a non-empty list, so a
                 pool without modules renders the machine config it rendered
                 before this field existed. */}}
          {{- $kernelModules := include "kubernetes-nodes.kernelModules" . }}
          {{- if $kernelModules }}
          kernel:
            modules:
              {{- $kernelModules | nindent 14 }}
          {{- end }}
          kubelet:
            image: ghcr.io/siderolabs/kubelet:{{ .kubeletVersion }}
            {{- /* Without this the kubelet never applies the
                  node.cloudprovider.kubernetes.io/uninitialized
                  taint, the Proxmox cloud-controller-manager
                  never gets to initialise the Node, and the
                  topology.kubernetes.io/{region,zone} labels are
                  never set. The CSI node plugin then exits
                  fatally on "Failed to get region or zone for
                  node", so the tenant ends up with a
                  StorageClass and no way to attach a volume.
                  The kubevirt path has no cloud provider and
                  must not carry the flag: it would taint every
                  worker with nothing to remove the taint. */}}
            {{- if eq ($.Values.substrate | default "kubevirt") "proxmox" }}
            extraArgs:
              cloud-provider: external
            {{- end }}
            extraConfig:
              systemReserved:
                cpu: "{{ .systemReservedCpu }}"
                memory: "{{ .systemReservedMemory }}"
              kubeReserved:
                cpu: "{{ .kubeReservedCpu }}"
                memory: "{{ .kubeReservedMemory }}"
              evictionHard:
                memory.available: "{{ .evictionHardMemory }}"
                nodefs.available: "10%"
                imagefs.available: "15%"
                nodefs.inodesFree: "5%"
              evictionSoft:
                memory.available: "{{ .evictionSoftMemory }}"
                nodefs.available: "15%"
                imagefs.available: "20%"
              evictionSoftGracePeriod:
                memory.available: "1m30s"
                nodefs.available: "1m30s"
                imagefs.available: "1m30s"
              evictionMinimumReclaim:
                memory.available: "256Mi"
          install:
            disk: /dev/vda
            image: {{ $.Values.talos.installerRepository | trimSuffix "/" | replace "\\" "\\\\" | replace "$" "\\$" | replace "`" "\\`" }}/{{ .talosSchematicID | replace "\\" "\\\\" | replace "$" "\\$" | replace "`" "\\`" }}:{{ .talosVersion | replace "\\" "\\\\" | replace "$" "\\$" | replace "`" "\\`" }}
            wipe: false
          features:
            rbac: true
            kubePrism:
              enabled: false
          {{- with $.Values.talos.registryMirrors }}
          registries:
            mirrors:
              {{- /* registryMirrors is free-form tenant-facing input rendered into the unquoted reconcile-Job heredoc above, so the value is escaped (backslash, dollar, backtick) to render as a literal and never be shell-expanded or command-substituted at Job runtime. This is a Helm comment: it is stripped at render, so its own text never reaches the heredoc. See cozystack/cozystack#3513. */}}
              {{- toYaml . | replace "\\" "\\\\" | replace "$" "\\$" | replace "`" "\\`" | nindent 14 }}
          {{- end }}
        cluster:
          id: ${CLUSTER_ID}
          secret: ${CLUSTER_SECRET}
          controlPlane:
            endpoint: https://${RELEASE}.${NS}.svc:6443
          clusterName: ${RELEASE}
          network:
            dnsDomain: {{ .dnsDomain }}
            podSubnets:
              - {{ .podCIDR }}
            serviceSubnets:
              - {{ .serviceCIDR }}
          token: ${BOOTSTRAP_TOKEN}
          ca:
            crt: ${K8S_CA_B64}
          discovery:
            enabled: true
            registries:
              kubernetes:
                disabled: true
              service:
                disabled: true
{{- end -}}

{{- /* The TalosConfigTemplate's name: kubernetes-<cluster>-<group>-<hash>, the hash
       taken over the spec above as this chart renders it, before the Job fills
       in its runtime inputs. CABPT's webhook rejects any change to a
       TalosConfigTemplate's spec, so a changed machineconfig has to be a new
       object; naming it by content is what moves the MachineDeployment's
       bootstrap.configRef, and so what makes CAPI roll the pool onto it. An
       unchanged render names the existing object and rolls nothing.

       nodegroup.yaml (configRef) and the Job (the object it applies) both take
       the name from here, so the two cannot disagree. The runtime inputs —
       apiserver address, CAs, tokens — stay out of the hash: they are not known
       at render time, and secrets have no business in an object name. */}}
{{- define "kubernetes-nodes.talosConfigTemplateNameFromContext" -}}
{{- printf "%s-%s-%s" .clusterName .groupName (include "kubernetes-nodes.talosConfigTemplateSpec" . | sha256sum | trunc 6) -}}
{{- end -}}

{{- define "kubernetes-nodes.talosConfigTemplateName" -}}
{{- $ctx := deepCopy . -}}
{{- include "kubernetes-nodes.talosConfigContext" (dict "root" . "out" $ctx) -}}
{{- include "kubernetes-nodes.talosConfigTemplateNameFromContext" $ctx -}}
{{- end -}}

{{- /* kubernetes-nodes.staleTalosConfigTemplates returns, as a JSON array, this
       pool's TalosConfigTemplates that nothing references any more. Called as
       (dict "root" $ "current" <this render's template name>).

       Every machineconfig change leaves the previous template behind, and the
       ownerReferences cannot reap it: KamajiControlPlane is the controller and
       CAPI adds the Cluster, and both outlive every revision of the pool. So the
       old ones are pruned the way the hash-named machine templates are kept in
       nodegroup.yaml: a template stays while any MachineSet (or the live
       MachineDeployment) still points at it, and goes on the first render after
       that stops. With revisionHistoryLimit 1 that leaves at most the current
       template, the one the retained MachineSet holds, and one on its way out.

       "This pool's" is decided exactly, never by name prefix — pool "md0" must
       not match a sibling "md0-a1b2c3": the template carries the
       cozystack.io/kubernetes-nodes-release label the Job stamps on it, or it is
       the stable kubernetes-<cluster>-<group> name every template had before
       content naming. Either way it must also be owned by this cluster's
       KamajiControlPlane. The current name is never returned.

       lookup is empty under helm template and helm-unittest without a
       kubernetesProvider, which returns an empty list: nothing is pruned. */}}
{{- define "kubernetes-nodes.staleTalosConfigTemplates" -}}
{{- $root := .root -}}
{{- $current := .current -}}
{{- $ns := $root.Release.Namespace -}}
{{- $clusterName := include "kubernetes-nodes.clusterName" $root -}}
{{- $legacyName := printf "%s-%s" $clusterName (include "kubernetes-nodes.groupName" $root) -}}
{{- $referenced := list -}}
{{- range (lookup "cluster.x-k8s.io/v1beta1" "MachineSet" $ns "").items | default list -}}
{{-   if eq (dig "spec" "template" "spec" "bootstrap" "configRef" "kind" "" .) "TalosConfigTemplate" -}}
{{-     $referenced = append $referenced (dig "spec" "template" "spec" "bootstrap" "configRef" "name" "" .) -}}
{{-   end -}}
{{- end -}}
{{- with lookup "cluster.x-k8s.io/v1beta1" "MachineDeployment" $ns $legacyName -}}
{{-   $referenced = append $referenced (dig "spec" "template" "spec" "bootstrap" "configRef" "name" "" .) -}}
{{- end -}}
{{- $stale := list -}}
{{- range (lookup "bootstrap.cluster.x-k8s.io/v1alpha3" "TalosConfigTemplate" $ns "").items | default list -}}
{{-   $name := .metadata.name -}}
{{-   $mine := or (eq (dig "metadata" "labels" "cozystack.io/kubernetes-nodes-release" "" .) $root.Release.Name) (eq $name $legacyName) -}}
{{-   $ownedByCluster := false -}}
{{-   range (dig "metadata" "ownerReferences" list .) -}}
{{-     if and (eq (.kind | default "") "KamajiControlPlane") (eq (.name | default "") $clusterName) -}}
{{-       $ownedByCluster = true -}}
{{-     end -}}
{{-   end -}}
{{-   if and $mine $ownedByCluster (ne $name $current) (not (has $name $referenced)) -}}
{{-     $stale = append $stale $name -}}
{{-   end -}}
{{- end -}}
{{- $stale | sortAlpha | toJson -}}
{{- end -}}

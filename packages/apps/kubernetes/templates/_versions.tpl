{{- define "kubernetes.versionMap" }}
{{- $ := . }}

{{- if not (hasKey $ "cachedVersionMap") }}
    {{- $versionMap := $.Files.Get "files/versions.yaml" | fromYaml }}
    {{- $_ := set $ "cachedVersionMap" $versionMap }}
{{- end }}

{{- $versionMap := $.cachedVersionMap }}

{{- if not (hasKey $versionMap $.Values.version) }}
    {{- printf `Kubernetes version %s is not supported, allowed versions are %s` $.Values.version (keys $versionMap) | fail }}
{{- end }}

{{- index $versionMap $.Values.version }}
{{- end }}

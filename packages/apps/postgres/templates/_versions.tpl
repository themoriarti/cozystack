{{- define "postgres.versionMap" }}
{{- $versionMap := .Files.Get "files/versions.yaml" | fromYaml }}
{{- if not (hasKey $versionMap .Values.version) }}
    {{- printf `PostgreSQL version %s is not supported, allowed versions are %s` $.Values.version (keys $versionMap) | fail }}
{{- end }}
{{- index $versionMap .Values.version }}
{{- end }}

{{- define "postgres.postgisVersionMap" }}
{{- $versionMap := .Files.Get "files/postgis-versions.yaml" | fromYaml }}
{{- if not (hasKey $versionMap .Values.version) }}
    {{- printf `PostgreSQL version %s is not supported by the postgis flavor, allowed versions are %s` $.Values.version (keys $versionMap | sortAlpha) | fail }}
{{- end }}
{{- index $versionMap .Values.version }}
{{- end }}

{{/*
  Single source for the operand image: the init Job runs psql against the
  Cluster, so both must resolve the same image.
*/}}
{{- define "postgres.imageName" -}}
{{- if eq (default "postgresql" .Values.flavor) "postgis" -}}
ghcr.io/cloudnative-pg/postgis:{{ include "postgres.postgisVersionMap" . | trim }}
{{- else -}}
ghcr.io/cloudnative-pg/postgresql:{{ include "postgres.versionMap" . | trim | trimPrefix "v" }}
{{- end -}}
{{- end -}}

{{/*
  The flavor is fixed at bootstrap. The two image families are built on
  different Debian releases, so moving a live cluster from one to the other
  swaps glibc under an initialised data directory and silently invalidates
  every index on collatable text; the postgis-to-postgresql direction also
  drops the shared libraries behind every PostGIS object. CNPG would roll
  either change out as an ordinary image update, so refuse it here, before
  the Cluster is patched. Only the image name is compared: a minor bump or
  a registry mirror rewriting the host must keep passing.
*/}}
{{- define "postgres.flavorGuard" -}}
{{- $live := lookup "postgresql.cnpg.io/v1" "Cluster" .Release.Namespace .Release.Name -}}
{{- if and $live $live.spec $live.spec.imageName -}}
{{- $liveName := regexReplaceAll "[:@].*$" (last (splitList "/" $live.spec.imageName)) "" -}}
{{- $wantName := regexReplaceAll "[:@].*$" (last (splitList "/" (include "postgres.imageName" .))) "" -}}
{{- if ne $liveName $wantName -}}
{{- fail (printf "postgres: flavor cannot change on an existing cluster (running %s, requested %s). The image families use different glibc versions, which would corrupt text indexes. Create a new Postgres with the wanted flavor and migrate the data, or restore a backup into it with bootstrap.enabled." $liveName $wantName) -}}
{{- end -}}
{{- end -}}
{{- end -}}

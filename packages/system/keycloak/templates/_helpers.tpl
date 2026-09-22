{{- /* Path prefixes the login host serves in the narrowed (ingress.adminHost)
       mode, as a YAML list — callers parse it with fromYamlArray.

       Realms are enumerated rather than covered by a bare /realms prefix: that
       prefix also publishes master, whose token endpoint then takes
       super-admin credentials from the internet. Both Ingress `pathType:
       Prefix` and Gateway API `PathPrefix` match on segment boundaries, so
       /realms/cozy does not reach a realm merely starting with "cozy".

       The charset guard mirrors authentication.oidc.realmName in
       packages/core/platform: the name is used verbatim as a URL path
       segment. */}}
{{- define "keycloak.loginPathPrefixes" -}}
{{- $realms := .Values.ingress.exposedRealms | default (list (index .Values._cluster "oidc-realm-name" | default "cozy")) }}
{{- range $realm := $realms }}
{{-   if not (kindIs "string" $realm) }}
{{-     fail (printf "ingress.exposedRealms entries must be strings (got %s); quote the realm name" (kindOf $realm)) }}
{{-   end }}
{{-   if not (regexMatch "^[a-zA-Z0-9][a-zA-Z0-9._-]*$" $realm) }}
{{-     fail (printf "ingress.exposedRealms entry %q is invalid: use only letters, digits, '.', '_' and '-'" $realm) }}
{{-   end }}
- {{ printf "/realms/%s" $realm | quote }}
{{- end }}
- "/resources"
- "/.well-known"
{{- end }}

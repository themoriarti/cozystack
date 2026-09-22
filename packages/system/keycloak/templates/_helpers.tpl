{{- /* Paths the login host serves in the narrowed (ingress.adminHost) mode, as
       a YAML list of {value, exact} — callers parse it with fromYamlArray.

       Realms are enumerated rather than covered by a bare /realms prefix: that
       prefix also publishes master, whose token endpoint then takes
       super-admin credentials from the internet.

       Each realm gets an exact path plus a prefix with the trailing slash,
       because ingress-nginx renders `pathType: Prefix` as a plain nginx
       prefix location (buildLocation() in
       internal/ingress/controller/template/template.go) rather than the
       element-wise match the Ingress API specifies — a lone /realms/cozy
       would also serve /realms/cozy-admin there. The pair is equivalent to
       the element-wise semantics on a conformant controller and on Gateway
       API, so it is emitted for both.

       The charset guard mirrors authentication.oidc.realmName in
       packages/core/platform: the name is used verbatim as a URL path
       segment. */}}
{{- define "keycloak.loginPaths" -}}
{{- $realms := .Values.ingress.exposedRealms }}
{{- $source := "ingress.exposedRealms" }}
{{- if $realms }}
{{-   if not (kindIs "slice" $realms) }}
{{-     fail (printf "ingress.exposedRealms must be a list of realm names (got %s), e.g. exposedRealms: [cozy]" (kindOf $realms)) }}
{{-   end }}
{{-   range $realm := $realms }}
{{-     if not (kindIs "string" $realm) }}
{{-       fail (printf "ingress.exposedRealms entries must be strings (got %s); quote the realm name" (kindOf $realm)) }}
{{-     end }}
{{-   end }}
{{- else }}
{{-   $realms = list (index .Values._cluster "oidc-realm-name" | default "cozy" | toString) }}
{{-   $source = "the platform realm name (authentication.oidc.realmName)" }}
{{- end }}
{{- range $realm := $realms }}
{{-   if not (regexMatch "^[a-zA-Z0-9][a-zA-Z0-9._-]*$" $realm) }}
{{-     fail (printf "%s: realm %q is invalid: use only letters, digits, '.', '_' and '-'" $source $realm) }}
{{-   end }}
- value: {{ printf "/realms/%s" $realm | quote }}
  exact: true
- value: {{ printf "/realms/%s/" $realm | quote }}
  exact: false
{{- end }}
- value: "/resources"
  exact: false
- value: "/.well-known"
  exact: false
{{- end }}

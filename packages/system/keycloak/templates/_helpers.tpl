{{- /* Paths the login host serves in the narrowed (ingress.adminHost) mode, as
       a YAML list of {value, exact} — callers parse it with fromYamlArray.

       Realms are enumerated rather than covered by a bare /realms prefix,
       which publishes every realm the deployment happens to have, master
       among them. That takes the super-admin login page and token endpoint
       off this hostname; reaching them is then a matter of which hostnames
       the edge accepts and which Gateway/ingressClass the admin route
       attaches to, and expose-ingress-admin defaults to the public one.

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
{{- $realmPattern := "^[a-zA-Z0-9][a-zA-Z0-9._-]*$" }}
{{- $platformRealm := dig "oidc-realm-name" "cozy" (.Values._cluster | default dict) | toString }}
{{- $extraRealms := .Values.ingress.exposedRealms }}
{{- if and $extraRealms (not (kindIs "slice" $extraRealms)) }}
{{-   fail (printf "ingress.exposedRealms must be a list of realm names (got %s), e.g. exposedRealms: [cozy-admin]" (kindOf $extraRealms)) }}
{{- end }}
{{- range $realm := $extraRealms }}
{{-   if not (kindIs "string" $realm) }}
{{-     fail (printf "ingress.exposedRealms entries must be strings (got %s); quote the realm name" (kindOf $realm)) }}
{{-   end }}
{{-   if not (regexMatch $realmPattern $realm) }}
{{-     fail (printf "ingress.exposedRealms: realm %q is invalid: use only letters, digits, '.', '_' and '-'" $realm) }}
{{-   end }}
{{-   if eq $realm "master" }}
{{-     fail "ingress.exposedRealms must not list master: it holds the Keycloak super-admin, whose login page and token endpoint would then accept those credentials on the public login hostname" }}
{{-   end }}
{{- end }}
{{- if not (regexMatch $realmPattern $platformRealm) }}
{{-   fail (printf "the platform realm name (authentication.oidc.realmName) %q is invalid: use only letters, digits, '.', '_' and '-'" $platformRealm) }}
{{- end }}
{{- if eq $platformRealm "master" }}
{{-   fail "the platform realm (authentication.oidc.realmName) must not be master: it holds the Keycloak super-admin, whose login page and token endpoint would then accept those credentials on the public login hostname" }}
{{- end }}
{{- /* The platform realm is what every component's issuer URL points at, so it
       is published whether or not exposedRealms names it. */}}
{{- range $realm := concat (list $platformRealm) ($extraRealms | default list) | uniq }}
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

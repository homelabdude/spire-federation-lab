{{/*
Fail early on missing or inconsistent environment values, instead of a
half-working install. Included from bundle-endpoint.yaml.
*/}}
{{- define "spire-lab.validate" -}}
{{- $s := .Values.spire -}}
{{- $oidc := index $s "spiffe-oidc-discovery-provider" -}}
{{- $issuer := printf "https://%s" .Values.oidcHost -}}
{{- range $k := list "trustDomain" "clusterName" }}
{{-   if not (index $.Values.global.spire $k) }}
{{-     fail (printf "global.spire.%s must be set (values.local.yaml)" $k) }}
{{-   end }}
{{- end }}
{{- if not .Values.oidcHost }}
{{-   fail "oidcHost must be set (values.local.yaml)" }}
{{- end }}
{{- if ne .Values.global.spire.jwtIssuer $issuer }}
{{-   fail (printf "global.spire.jwtIssuer must be %s (got %q)" $issuer .Values.global.spire.jwtIssuer) }}
{{- end }}
{{- if ne $oidc.gatewayAPI.host .Values.oidcHost }}
{{-   fail (printf "spire.spiffe-oidc-discovery-provider.gatewayAPI.host must be %s (got %q)" .Values.oidcHost $oidc.gatewayAPI.host) }}
{{- end }}
{{- if ne $oidc.config.jwksUri (printf "%s/keys" $issuer) }}
{{-   fail (printf "spire.spiffe-oidc-discovery-provider.config.jwksUri must be %s/keys (got %q)" $issuer $oidc.config.jwksUri) }}
{{- end }}
{{- if ne (index $s "spire-server").controllerManager.className .Values.federation.className }}
{{-   fail "federation.className must match spire.spire-server.controllerManager.className" }}
{{- end }}
{{- if not .Values.bundleEndpoint.loadBalancerIP }}
{{-   fail "bundleEndpoint.loadBalancerIP must be set (values.local.yaml)" }}
{{- end }}
{{- if .Values.federation.enabled }}
{{-   range $k := list "trustDomain" "bundleEndpointURL" "trustDomainBundle" }}
{{-     if not (index $.Values.federation $k) }}
{{-       fail (printf "federation.%s must be set when federation.enabled is true" $k) }}
{{-     end }}
{{-   end }}
{{- end }}
{{- end }}

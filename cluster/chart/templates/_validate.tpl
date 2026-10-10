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
{{- if .Values.serverEndpoint.enabled }}
{{-   if not .Values.serverEndpoint.loadBalancerIP }}
{{-     fail "serverEndpoint.loadBalancerIP must be set when serverEndpoint.enabled is true" }}
{{-   end }}
{{-   if not .Values.serverEndpoint.allowedSourceRanges }}
{{-     fail "serverEndpoint.allowedSourceRanges must list the agent hosts when serverEndpoint.enabled is true" }}
{{-   end }}
{{- end }}
{{- $x509pop := (index $s "spire-server").nodeAttestor.x509POP }}
{{- if $x509pop.enabled }}
{{-   if ne $x509pop.mode "externalPKI" }}
{{-     fail "spire.spire-server.nodeAttestor.x509POP.mode must be externalPKI (node certs from the enrollment CA)" }}
{{-   end }}
{{-   if not (or $x509pop.caBundle.bundle $x509pop.caBundle.existingConfigMap) }}
{{-     fail "x509pop needs the enrollment CA: run `make x509pop-ca` (the Makefile passes out/x509pop-ca.pem)" }}
{{-   end }}
{{-   if not .Values.nodeAliases }}
{{-     fail "nodeAliases must list the node cert CNs when x509pop is enabled" }}
{{-   end }}
{{-   range .Values.nodeAliases }}
{{-     if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .) }}
{{-       fail (printf "nodeAliases: %q must be a DNS label (it's also the ClusterStaticEntry name)" .) }}
{{-     end }}
{{-   end }}
{{- end }}
{{- if .Values.tornjakRoute.enabled }}
{{-   $r := .Values.tornjakRoute }}
{{-   range $k := list "tenantID" "clientID" }}
{{-     if not (index $r.oidc $k) }}
{{-       fail (printf "tornjakRoute.oidc.%s must be set when tornjakRoute.enabled is true (terraform output tornjak_oidc)" $k) }}
{{-     end }}
{{-   end }}
{{-   if not $r.host }}
{{-     fail "tornjakRoute.host must be set when tornjakRoute.enabled is true" }}
{{-   end }}
{{-   $api := index $s "tornjak-frontend" "apiServerURL" }}
{{-   if ne $api (printf "https://%s" $r.host) }}
{{-     fail (printf "spire.tornjak-frontend.apiServerURL must be https://%s with the route (got %q)" $r.host $api) }}
{{-   end }}
{{- end }}
{{- if .Values.federation.enabled }}
{{-   range $k := list "trustDomain" "bundleEndpointURL" "trustDomainBundle" }}
{{-     if not (index $.Values.federation $k) }}
{{-       fail (printf "federation.%s must be set when federation.enabled is true" $k) }}
{{-     end }}
{{-   end }}
{{- end }}
{{- end }}

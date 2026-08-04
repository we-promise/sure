{{/*
Mutual exclusivity and configuration guards
*/}}

{{- if and .Values.redisOperator.managed.enabled .Values.redisSimple.enabled -}}
{{- fail "Invalid configuration: Both redisOperator.managed.enabled and redisSimple.enabled are true. Enable only one in-cluster Redis provider." -}}
{{- end -}}

{{- $extEnabled := false -}}
{{- if .Values.rails -}}{{- if .Values.rails.externalAssistant -}}{{- if .Values.rails.externalAssistant.enabled -}}
{{- $extEnabled = true -}}
{{- end -}}{{- end -}}{{- end -}}
{{- $plEnabled := false -}}
{{- if .Values.pipelock -}}{{- if .Values.pipelock.enabled -}}
{{- $plEnabled = true -}}
{{- end -}}{{- end -}}
{{- $requirePL := false -}}
{{- if .Values.pipelock -}}{{- if .Values.pipelock.requireForExternalAssistant -}}
{{- $requirePL = true -}}
{{- end -}}{{- end -}}
{{- if and $extEnabled (not $plEnabled) $requirePL -}}
{{- fail "pipelock.requireForExternalAssistant is true but pipelock.enabled is false. Enable pipelock (pipelock.enabled=true) when using rails.externalAssistant, or set pipelock.requireForExternalAssistant=false." -}}
{{- end -}}

{{/*
Pipelock 2.x rejects an enabled mcp_tool_policy with no rules; surface this
at helm template time instead of waiting for the container to crash-loop.
*/}}
{{/*
Gate on the effective value, not on key presence: an absent `enabled` key
defaults to false in pipelock-configmap.yaml, so `$mtp.enabled` alone is the
same condition the ConfigMap renders.
*/}}
{{- if $plEnabled -}}
{{- $mtp := .Values.pipelock.mcpToolPolicy | default (dict) -}}
{{- if $mtp.enabled -}}
{{- if eq (len ($mtp.rules | default (list))) 0 -}}
{{- fail "pipelock.mcpToolPolicy.enabled=true requires at least one entry in pipelock.mcpToolPolicy.rules. Pipelock rejects an enabled tool policy with no rules." -}}
{{- end -}}
{{- end -}}
{{- end -}}

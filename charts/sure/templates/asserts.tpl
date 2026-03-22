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

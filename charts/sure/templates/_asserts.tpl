{{/*
Mutual exclusivity and configuration guards
*/}}

{{- if and .Values.redisOperator.managed.enabled .Values.redisSimple.enabled -}}
{{- fail "Invalid configuration: Both redisOperator.managed.enabled and redisSimple.enabled are true. Enable only one in-cluster Redis provider." -}}
{{- end -}}

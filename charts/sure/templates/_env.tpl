{{/*
Shared environment variable helpers for Rails workloads.

Usage examples (indent with nindent in caller):

  {{ include "sure.env" (dict "ctx" . "includeDatabase" true "includeRedis" true "extraEnv" .Values.worker.extraEnv "extraEnvFrom" .Values.worker.extraEnvFrom) | nindent 10 }}

The helper always injects:
- RAILS_ENV
- SECRET_KEY_BASE
- optional Active Record Encryption keys (controlled by rails.encryptionEnv.enabled)
- optional DATABASE_URL + DB_PASSWORD (includeDatabase=true and helper can compute a DB URL)
- optional REDIS_URL + REDIS_PASSWORD (includeRedis=true and helper can compute a Redis URL)
- rails.settings / rails.extraEnv / rails.extraEnvVars
- optional additional per-workload env / envFrom blocks via extraEnv / extraEnvFrom.
*/}}

{{- define "sure.env" -}}
{{- $ctx := .ctx -}}
{{- $includeDatabase := default true .includeDatabase -}}
{{- $includeRedis := default true .includeRedis -}}
{{- $extraEnv := .extraEnv | default (dict) -}}
{{- $extraEnvFrom := .extraEnvFrom -}}

- name: RAILS_ENV
  value: {{ $ctx.Values.rails.env | quote }}
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ include "sure.appSecretName" $ctx }}
      key: SECRET_KEY_BASE
{{- if $ctx.Values.rails.encryptionEnv.enabled }}
- name: ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "sure.appSecretName" $ctx }}
      key: ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
- name: ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "sure.appSecretName" $ctx }}
      key: ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
- name: ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
  valueFrom:
    secretKeyRef:
      name: {{ include "sure.appSecretName" $ctx }}
      key: ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
{{- end }}
{{- if $includeDatabase }}
{{- $dburl := include "sure.databaseUrl" $ctx -}}
{{- if $dburl }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "sure.dbSecretName" $ctx }}
      key: {{ include "sure.dbPasswordKey" $ctx }}
- name: DATABASE_URL
  value: {{ $dburl | quote }}
{{- end }}
{{- end }}
{{- if $includeRedis }}
{{- $redis := include "sure.redisUrl" $ctx -}}
{{- if $redis }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "sure.redisSecretName" $ctx }}
      key: {{ include "sure.redisPasswordKey" $ctx }}
- name: REDIS_URL
  value: {{ $redis | quote }}
{{- $sentinelHosts := include "sure.redisSentinelHosts" $ctx -}}
{{- if $sentinelHosts }}
- name: REDIS_SENTINEL_HOSTS
  value: {{ $sentinelHosts | quote }}
- name: REDIS_SENTINEL_MASTER
  value: {{ include "sure.redisSentinelMaster" $ctx | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- range $k, $v := $ctx.Values.rails.settings }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- range $k, $v := $ctx.Values.rails.extraEnv }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- with $ctx.Values.rails.extraEnvVars }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- range $k, $v := $extraEnv }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}

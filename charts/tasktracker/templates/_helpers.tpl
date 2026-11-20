{{- /*
=============================================================================
File        : charts/tasktracker/templates/_helpers.tpl
Assignment  : DSO202 Assignment 4
Descriptor  : Unit III 3.2 - Helm named templates
Purpose     : Shared labels, selectors and environment rendering, so every
              tier is rendered the same way.
=============================================================================
*/}}

{{/* Common labels on every object. */}}
{{- define "tasktracker.labels" -}}
app.kubernetes.io/part-of: tasktracker
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/* Selector labels for one tier. Call with (dict "root" $ "component" "backend"). */}}
{{- define "tasktracker.selector" -}}
app.kubernetes.io/name: tasktracker-{{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{/*
Container environment for one tier. Call with (dict "root" $ "tier" .Values.<tier>).
  C2: tier.env       is a map NAME -> value, rendered as plain variables.
  C3: tier.secretEnv is a map NAME -> key in the Secret named by existingSecret.
Keys are rendered in sorted order, so the output is stable between renders
(an unstable order would make Argo CD report a diff on every comparison).
*/}}
{{- define "tasktracker.env" -}}
{{- range $name, $value := .tier.env }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- range $name, $key := .tier.secretEnv }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ required "existingSecret must be set (C3)" $.root.Values.existingSecret }}
      key: {{ $key }}
{{- end }}
{{- end }}

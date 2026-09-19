{{/*
Common labels applied to every rendered object. These land in other namespaces,
so they need to be self-identifying.
*/}}
{{- define "volsync-backups.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: volsync-backups
{{- end -}}

{{/*
Name of the Secret (and the ExternalSecret that produces it) holding this entry's
restic credentials. Keyed on `app` so entries sharing a namespace - the 11 media
apps - never collide.
Usage: include "volsync-backups.secretName" $entry
*/}}
{{- define "volsync-backups.secretName" -}}
{{ .app }}-volsync-restic
{{- end -}}

{{/*
Repository URL for an entry: <base>/<namespace>-<app>. Namespace-qualified so the
path is unique across the whole cluster.
Usage: include "volsync-backups.repository" (dict "root" $ "entry" $entry)
*/}}
{{- define "volsync-backups.repository" -}}
{{- $base := .root.Values.defaults.repositoryBaseUrl | trimSuffix "/" -}}
{{- printf "%s/%s-%s" $base .entry.namespace .entry.app -}}
{{- end -}}

{{/*
Cron schedule for an entry. An explicit `schedule:` on the entry wins; otherwise
one is derived from the entry's position in the list so the movers run in single
file rather than all at once:

    minute = (index mod staggerPerHour) * staggerMinutes
    hour   = staggerStartHour + (index div staggerPerHour)

With the defaults that places backups at 01:00, 01:10 ... 04:10, one every ten
minutes. Positions come from the raw list index, so toggling an entry's `enabled`
flag leaves every other schedule untouched.

Usage: include "volsync-backups.schedule" (dict "root" $ "entry" $entry "index" $i)
*/}}
{{- define "volsync-backups.schedule" -}}
{{- if .entry.schedule -}}
{{- .entry.schedule -}}
{{- else -}}
{{- $d := .root.Values.defaults -}}
{{- $minute := mul (mod .index (int $d.staggerPerHour)) (int $d.staggerMinutes) -}}
{{- $hour := mod (add (int $d.staggerStartHour) (div .index (int $d.staggerPerHour))) 24 -}}
{{- printf "%d %d * * *" $minute $hour -}}
{{- end -}}
{{- end -}}

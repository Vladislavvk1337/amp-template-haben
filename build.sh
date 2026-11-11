#!/usr/bin/env bash
# Erzeugt habenupdates.json aus src/habenupdates.template.json und src/haben.sh.
# AMP lädt aus einem Template-Repository nur die Manifest-Dateien; das Skript reist deshalb base64-kodiert in der
# Update-Stufe mit. Nach jeder Änderung an src/ ausführen und habenupdates.json mit einchecken.
#
#   ./build.sh          habenupdates.json neu schreiben
#   ./build.sh --check  nur prüfen, ob habenupdates.json aktuell ist (für CI)
set -euo pipefail
cd "$(dirname "$0")"

script=src/haben.sh
template=src/habenupdates.template.json
out=habenupdates.json

bash -n "$script"
# Windows-Zeilenenden würden das Skript im Container zerbrechen
if grep -q $'\r' "$script"; then
  echo "FEHLER: $script enthält CRLF-Zeilenenden" >&2
  exit 1
fi

b64="$(base64 -w0 < "$script")"
sha="$(sha256sum < "$script" | cut -c1-12)"
generated="$(sed -e "s|@@HABEN_SH_BASE64@@|$b64|" -e "s|@@HABEN_SH_SHA256@@|$sha|" "$template")"

if [ "${1:-}" = "--check" ]; then
  if [ "$generated" != "$(cat "$out")" ]; then
    echo "FEHLER: $out ist nicht aktuell, ./build.sh ausführen" >&2
    exit 1
  fi
  echo "$out ist aktuell ($sha)"
  exit 0
fi

printf '%s\n' "$generated" > "$out"
echo "$out geschrieben (haben.sh $sha, $(wc -c < "$script") Byte)"

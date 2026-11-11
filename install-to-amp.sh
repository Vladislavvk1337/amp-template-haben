#!/usr/bin/env bash
# Kopiert das Haben-Template in den Template-Ordner des AMP-Controllers (ADS), auf dem AMP-Host ausführen:
#
#   sudo -u amp ./install-to-amp.sh                       # Vorgabe: ADS-Instanz ADS01
#   sudo -u amp ./install-to-amp.sh /pfad/zu/ADS01        # andere ADS-Instanz
#
# Danach den Controller neu starten (sudo -u amp ampinstmgr restart ADS01), dann taucht "Haben" beim
# Anlegen einer Instanz unter "Generic" bzw. in der Anwendungsliste auf.
set -euo pipefail
cd "$(dirname "$0")"

ads="${1:-${AMP_ADS_DIR:-$HOME/.ampdata/instances/ADS01}}"
[ -d "$ads" ] || {
  echo "ADS-Instanz nicht gefunden: $ads (als Benutzer amp ausführen oder Pfad angeben)" >&2
  exit 1
}
dest="$ads/Plugins/ADSModule/GenericTemplates"
mkdir -p "$dest"

./build.sh --check
for f in haben.kvp habenconfig.json habenmetaconfig.json habenports.json habenupdates.json; do
  install -m 644 "$f" "$dest/$f"
  echo "kopiert: $dest/$f"
done
echo "Fertig. Jetzt den Controller neu starten: ampinstmgr restart $(basename "$ads")"

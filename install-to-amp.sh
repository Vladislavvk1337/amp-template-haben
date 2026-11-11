#!/usr/bin/env bash
# Legt das Haben-Template als lokale Template-Quelle im AMP-Controller (ADS) an, auf dem AMP-Host ausführen.
# Nur nötig, wenn das Template nicht über Configuration Repositories (öffentliches GitHub) kommen soll.
#
#   sudo -u amp ./install-to-amp.sh                       # Vorgabe: ADS-Instanz ADS01
#   sudo -u amp ./install-to-amp.sh /pfad/zu/ADS01        # andere ADS-Instanz
#
# Ziel laut AMP-Wiki: Plugins/ADSModule/DeploymentTemplates/LOCAL-<name>-main mit manifest.json.
# Danach den Controller neu starten (sudo -u amp ampinstmgr restart ADS01) und den Browser neu laden.
set -euo pipefail
cd "$(dirname "$0")"

ads="${1:-${AMP_ADS_DIR:-$HOME/.ampdata/instances/ADS01}}"
[ -d "$ads" ] || {
  echo "ADS-Instanz nicht gefunden: $ads (als Benutzer amp ausführen oder Pfad angeben)" >&2
  exit 1
}
dest="$ads/Plugins/ADSModule/DeploymentTemplates/LOCAL-amp-template-haben-main"
mkdir -p "$dest"

./build.sh --check
for f in manifest.json haben.kvp habenconfig.json habenmetaconfig.json habenports.json habenupdates.json; do
  install -m 644 "$f" "$dest/$f"
  echo "kopiert: $dest/$f"
done
echo "Fertig. Jetzt den Controller neu starten: ampinstmgr restart $(basename "$ads")"

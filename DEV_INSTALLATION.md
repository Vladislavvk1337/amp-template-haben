# Instanz einrichten und testen

Anleitung, um das Template in AMP einzubinden, eine Haben-Instanz aufzusetzen und alles einmal durchzutesten:
Installation, Betrieb, Datenbank-Schutz, AMP-Backups (lokal und S3), restic und Wiederherstellung.
Wer am Template selbst entwickelt, findet am Ende den Ablauf für Änderungen und einen Schnelltest ohne AMP.

Platzhalter: `<Instanz>` ist der Instanzname in AMP (z. B. `Haben01`), `<ads>` die ADS-Instanz (meist `ADS01`).
Der Instanzordner liegt auf dem Host unter `/home/amp/.ampdata/instances/<Instanz>/`.

## 1. Voraussetzungen prüfen

- [ ] AMP 2.6.2.6 oder neuer, Linux-Host, Docker installiert und in AMP aktiv
      (*Configuration › Instance Deployment › Use Docker Containers* bzw. beim Anlegen „Container“).
- [ ] Mindestens 2 CPU-Kerne, 4 GB RAM frei für den ersten Build, 3 GB Platz.
- [ ] Eine Domain für Haben, die auf den Server zeigt, und ein Reverse Proxy mit HTTPS (Caddy, nginx, Traefik).
      Zum reinen Testen geht auch eine Test-Subdomain.

## 2. Template in AMP einbinden

**Variante A, über GitHub (empfohlen):** Das Repository muss öffentlich sein.

1. *Configuration › Instance Deployment › Configuration Repositories*: `Vladislavvk1337/amp-template-haben:main`
   hinzufügen.
2. *Fetch latest*, danach den **Browser neu laden** (F5).
3. Prüfen: Beim Anlegen einer Instanz erscheint **Haben** in der Anwendungsliste (Quelle bzw. Präfix `amp-haben`).
   Fehlt es: Im Repository muss `manifest.json` im Hauptverzeichnis liegen; im AMP-Log nach
   `Vladislavvk1337/amp-template-haben` suchen. Hilft das nicht, ADS neu starten (`ampinstmgr restart ADS01`).

**Variante B, Dateien auf den Host kopieren** (auch für private Forks):

```bash
sudo -iu amp
```

```bash
git clone https://github.com/Vladislavvk1337/amp-template-haben.git && cd amp-template-haben
```

```bash
./install-to-amp.sh && ampinstmgr restart ADS01
```

## 3. Instanz anlegen und installieren

1. *Create Instance* › **Haben**, Name z. B. `Haben01`, Container-Modus.
2. *Configuration › Haben › Allgemein › Öffentliche Adresse*: `https://haben.example.de` (ohne `/` am Ende).
3. **Update** klicken und die Konsole beobachten. Erwartet:
   - `Lade Haben aus https://github.com/firsttris/haben.git …`
   - `Installiere Bun 1.x.x …`, `Installiere Abhängigkeiten …`, `Baue Haben vX.Y.Z …`
   - `Lege die Datenbank an (PostgreSQL 17) …`
   - `Fertig: Haben vX.Y.Z ist installiert.`
4. Im Dateimanager prüfen: `haben/data/schluessel.env` existiert. **Inhalt jetzt in den Passwortmanager.**

Schlägt das Update fehl: Meldung in der Konsole, Details in `haben/logs/`. Häufig: zu wenig RAM beim Build
(Instanz-Limits erhöhen) oder kein Internet im Container.

## 4. Reverse Proxy

Den Web-Port der Instanz (*Network & Ports*, Vorgabe 3000) per HTTPS veröffentlichen, Beispiel Caddy:

```
haben.example.de {
  request_body {
    max_size 250MB
  }
  reverse_proxy 127.0.0.1:3000
}
```

## 5. Starten und einrichten

1. **Start**. Erwartet in der Konsole:
   - `Starte PostgreSQL …` (ohne Fehler), `Migrationen angewendet`
   - `Haben ist noch nicht eingerichtet. Einrichtungscode für https://haben.example.de/setup: …`
   - `Haben ist bereit: https://haben.example.de` → AMP zeigt **Running**.
2. `https://haben.example.de/setup` öffnen, Einrichtungscode eingeben, erstes Konto anlegen.
3. Firmendaten, Nummernkreis und ggf. ELSTER einrichten ([Erste Schritte](https://haben.app/einrichtung.html)).

## 6. Funktionstest

- [ ] Anmelden, abmelden, wieder anmelden (Passkey oder Passwort).
- [ ] Testkunde und Testrechnung anlegen, PDF-Vorschau erscheint.
- [ ] Einen PDF-Beleg hochladen; er erscheint unter Belege (prüft Poppler und `data/belege/`).
- [ ] **Stop**: Konsole zeigt `Beende Haben …`, `Beende PostgreSQL …`, `Haben beendet.`; AMP zeigt **Stopped**.
- [ ] **Start** erneut: Daten sind noch da.
- [ ] **Restart** und AMP-Neustart des Hosts überstehen (Instanz startet automatisch, falls in AMP eingestellt).
- [ ] Konsolenbefehl `hilfe` listet die Befehle.

## 7. Datenbank-Schutz testen

Erwartet ist: Die Datenbank ist nur innerhalb des Containers und nur mit Passwort erreichbar.

- [ ] *Network & Ports* der Instanz zeigt **nur** den Web-Port, keinen Datenbank-Port.
- [ ] In der Konsole beim Start keine Meldung `lauscht auf … statt nur auf 127.0.0.1`.
- [ ] Vom Host bzw. einem anderen Rechner ist der Port zu (Vorgabe 54320):

  ```bash
  nc -zv <server-ip> 54320
  ```

  Erwartet: `Connection refused` oder Zeitüberschreitung.
- [ ] Im Container lauscht PostgreSQL nur auf 127.0.0.1:

  ```bash
  docker exec AMP_<Instanz> sh -c 'cat /proc/net/tcp | awk "NR>1 && \$4==\"0A\" {print \$2}"'
  ```

  Erwartet: `0100007F:D430` (127.0.0.1:54320) und der Web-Port, nichts mit `00000000:D430`.
- [ ] Ohne Passwort kein Zugang:

  ```bash
  docker exec -u amp AMP_<Instanz> sh -c 'psql -h 127.0.0.1 -p 54320 -U haben -w -d haben -c "select 1"'
  ```

  Erwartet: `fe_sendauth: no password supplied`.
- [ ] `haben/pgdata/pg_hba.conf` enthält nur die zwei Zeilen von amp-haben; eine Änderung daran ist nach dem
      nächsten Start wieder weg.

## 8. AMP-Backups testen (lokal und S3)

**Lokal**

1. Konsolenbefehl `dump` → `Lokaler Dump erneuert: …/backups/haben-aktuell.sql.gz`.
2. *Backups › Create Backup*.
3. Backup herunterladen oder im Dateimanager ansehen: enthält `haben/data/`, `haben/backups/haben-aktuell.sql.gz`,
   **nicht** `haben/pgdata/`, `haben/app/`, `haben/bun/`.

**S3**

1. Bucket anlegen (eigener Bucket je Server, Lifecycle „nur letzte Version behalten“), Schlüssel nur für diesen Bucket.
2. *Configuration › Backups › Cloud*: „Use S3 Storage for Backups“ an, *S3 Service URL* (mit `https://`),
   *Bucket*, *Access Key*, *Secret Key*, *S3 Backup Count Limit* (z. B. 14) und *S3 Backup Space Limit*.
3. *Schedule › Add new trigger*: täglich z. B. 02:00, Aufgaben in dieser Reihenfolge:
   **Send console command** `dump`, dann **Backups › Take a backup** mit S3.
4. Trigger einmal von Hand auslösen; das Backup erscheint in AMP und im Bucket.

**Wiederherstellung aus einem AMP-Backup**

1. In Haben etwas Erkennbares ändern (z. B. Kunde „Test vor Backup“ anlegen), `dump`, Backup erstellen.
2. Danach etwas Neues anlegen (Kunde „Nach Backup“).
3. Instanz stoppen, das Backup in AMP wiederherstellen (bei S3 vorher „Download from S3“), starten.
4. Erwartet in der Konsole: `AMP-Backup wurde wiederhergestellt: der Dump in backups/ passt nicht zur Datenbank`,
   `Bisherige Datenbank verschoben nach …/alt/pgdata-…`, `Datenbank wiederhergestellt.`
5. In Haben: „Test vor Backup“ ist da, „Nach Backup“ nicht.
6. Wenn alles passt, `haben/alt/pgdata-…` im Dateimanager löschen.

## 9. restic testen

1. *Configuration › Haben › Sicherung*: Ziel **S3** (oder zum ersten Test **Lokal**), Endpunkt, Bucket, Pfad,
   Access/Secret Key eintragen. Aufbewahrung auf den Vorgaben lassen. Instanz neu starten.
   Erwartet: `Nächste restic-Sicherung: <Datum> 03:15`.
2. Konsolenbefehl `sicherung`. Erwartet: `Lege das restic-Repository an …` (nur beim ersten Mal),
   `Snapshot xxxxxxxx: N Dateien, … Byte`, `Aufbewahrung angewendet: …`.
3. In Haben unter Einstellungen › Export steht die erfolgreiche Sicherung.
4. Konsolenbefehl `pruefung`. Erwartet: `Test-Restore bestanden: … Tabellen, Kette bis Nr. … geprüft …, N Belege …`.
5. Konsolenbefehl `snapshots` listet den Stand.
6. **Wiederherstellung aus restic**: Instanz stoppen, `haben/data/WIEDERHERSTELLEN` mit Inhalt `restic latest`
   anlegen, starten. Erwartet: `Hole restic-Snapshot latest …`, `Datenbank wiederhergestellt.`,
   `Belege wiederhergestellt; …`. Die Datei heißt danach `WIEDERHERSTELLEN.erledigt-<Zeit>`.
7. Gegenprobe Fehlerfall: falschen Secret Key eintragen, `sicherung` → Fehlermeldung in der Konsole und in Haben.
   Danach den richtigen Schlüssel wieder eintragen.

**Ernstfall-Probe** (empfohlen einmal vor dem Echtbetrieb): neue Instanz auf einem anderen Host anlegen, gleiche
*Schlüssel* (`AUTH_SECRET`, `ENCRYPTION_KEY`) und gleiches restic-Passwort und -Ziel eintragen, *Update*,
`restic latest` in `data/WIEDERHERSTELLEN`, starten, anmelden, Daten und ELSTER-Zertifikat prüfen.

## 10. Update testen

1. *Configuration › Updates › Haben-Version* auf eine ältere Version setzen (z. B. `v0.6.5`), *Update*, starten.
2. Auf leer (= neuestes Release) zurücksetzen, *Update*. Erwartet: `Datenbank vor dem Update gesichert
   (…/backups/vor-update)`, danach Build und `Fertig`.
3. Start: `Migrationen angewendet`, Daten sind da.
4. Rücknahme-Probe: Version wieder auf die alte, *Update*, `vor-update` in `data/WIEDERHERSTELLEN`, starten.

## Fehlersuche

| Symptom | Ursache / Abhilfe |
|---|---|
| Update: `'restic' fehlt` o. Ä. | Instanz läuft nicht im Container; neu im Container-Modus anlegen. |
| Start: `Öffentliche Adresse fehlt` | *Haben › Allgemein* ausfüllen. |
| Start: `stammt von PostgreSQL 17, im Container gibt es aber nur …` | siehe README, PostgreSQL-Upgrade. |
| Start hängt bei „Starting“ | Konsole lesen; Haben antwortet nicht auf `/login`. `haben/logs/postgresql.log` prüfen. |
| Anmeldung scheitert, Passkey geht nicht | Öffentliche Adresse ≠ Adresse im Browser, oder kein HTTPS. |
| `Eine andere Sicherung läuft noch` | restic-Sicherung läuft; warten. |

Protokolle: AMP-Konsole, `haben/logs/postgresql.log`, `haben/logs/wiederherstellung.log`,
`haben/backup-state/status` (letzte restic-Sicherung).

## Am Template entwickeln

1. `src/haben.sh`, `haben.kvp` oder `habenconfig.json` ändern.
2. `./build.sh` (bettet `src/haben.sh` in `habenupdates.json` ein), `./build.sh --check` muss passen.
3. Commit und Push; die CI prüft Syntax, ShellCheck und JSON.
4. In AMP *Configuration › Instance Deployment › Fetch latest* (bzw. `install-to-amp.sh` erneut), dann in der
   Test-Instanz *Update*: Die Update-Stufe schreibt `haben/scripts/haben.sh` neu.
5. Nach Änderungen an `haben.kvp` (Pakete, Umgebungsvariablen) die Instanz neu starten; neue Container-Pakete
   greifen erst mit einem neu erzeugten Container (Instanz einmal über AMP neu erstellen bzw. Container neu bauen).

### Schnelltest ohne AMP

Das Skript lässt sich in einem einfachen Debian-Container testen (Docker auf einem Linux-Rechner):

```bash
docker run -it --rm -p 3000:3000 -v "$PWD":/t:ro debian:trixie bash
```

Im Container:

```bash
apt-get update && apt-get install -y --no-install-recommends postgresql restic poppler-utils fonts-liberation git unzip curl ca-certificates tzdata util-linux gzip && useradd -m amp
```

```bash
su amp -c 'HABEN_ROOT=/home/amp/haben/ bash /t/src/haben.sh install'
```

```bash
su amp -c 'HABEN_ROOT=/home/amp/haben/ BETTER_AUTH_URL=http://localhost:3000 bash /t/src/haben.sh run'
```

Dann `http://localhost:3000/setup` (Passkeys gehen über `localhost` auch ohne HTTPS). Mit Strg+C beenden: Das
Skript fährt Haben und PostgreSQL sauber herunter.

# amp-template-haben

AMP-Template ([CubeCoders AMP](https://cubecoders.com/AMP), Generic Module) für
[Haben](https://github.com/firsttris/haben), die selbst gehostete Open-Source-Buchhaltung für Freiberufler,
Selbstständige und kleine GmbHs: Rechnungen mit ZUGFeRD/XRechnung, Belege, Bankabgleich, EÜR oder Bilanz und
Übermittlung an ELSTER.

Damit legst du in AMP eine Instanz „Haben“ an, die du wie jeden anderen Server installierst, aktualisierst,
startest, stoppst und sicherst. Schritt für Schritt einrichten und testen: [DEV_INSTALLATION.md](DEV_INSTALLATION.md).

## Was die Instanz macht

| Schritt in AMP | Was passiert |
|---|---|
| **Update** | Haben aus dem Git-Repository holen (neuestes Release oder gewählte Version), die passende Bun-Version installieren, Haben bauen, Datenbank anlegen. Vor jedem Versionswechsel wird die Datenbank nach `backups/vor-update/` gesichert. |
| **Start** | Falls nötig wiederherstellen (siehe unten), eingebettete PostgreSQL abgesichert starten, Migrationen anwenden, Haben starten. Die Instanz ist „Running“, sobald Haben auf `/login` antwortet. |
| **Stop** | Haben beenden, letzten Dump schreiben, PostgreSQL sauber beenden. |
| **Laufend** | Dump für AMP-Backups (stündlich), optional tägliche restic-Sicherung mit Aufbewahrung und Test-Restore. |

Aufbau einer Instanz (`<Instanz>/haben/`):

```
app/           Quellen und Build von Haben (bei jedem Update ersetzt)          nicht in AMP-Backups
bun/           Bun-Laufzeit                                                     nicht in AMP-Backups
pgdata/        PostgreSQL-Datenbank (eingebettet)                               nicht in AMP-Backups
data/          belege/, eric/, ssh/, schluessel.env, haben.env, WIEDERHERSTELLEN
backups/       haben-aktuell.sql.gz (für AMP-Backups), vor-update/
restic/        restic-Repository bei Ziel „Lokal“ ohne eigenen Pfad             nicht in AMP-Backups
alt/           beim Wiederherstellen beiseitegelegte Stände                     nicht in AMP-Backups
logs/          postgresql.log, ERiC-Protokolle
scripts/       haben.sh (aus dem Template erzeugt)
```

## Voraussetzungen

- AMP 2.6.2.6 oder neuer auf **Linux**, Instanzen **im Docker-Container** (das Template verlangt das). Das
  Container-Image `cubecoders/ampbase:debian` bekommt beim Start die nötigen Pakete (`postgresql`, `restic`,
  `poppler-utils`, `fonts-liberation`, `git`, `unzip` …).
- x86_64 oder arm64. ELSTER (ERiC) gibt es nur für x86_64.
- Für den Build beim Update etwa 2 CPU-Kerne und 4 GB RAM, im Betrieb deutlich weniger. Etwa 3 GB Platz.
- Ein **Reverse Proxy mit HTTPS** vor dem Web-Port. Passkeys und sichere Cookies funktionieren nur über HTTPS
  unter der eingestellten öffentlichen Adresse.

## Template in AMP einbinden

In AMP unter *Configuration › Instance Deployment › Configuration Repositories* eintragen:

```
Vladislavvk1337/amp-template-haben:main
```

Dann *Fetch latest*. AMP liest Configuration Repositories nur aus **öffentlichen GitHub-Repositories**.
Alternativ die Dateien direkt auf den AMP-Host kopieren: `./install-to-amp.sh` (siehe
[DEV_INSTALLATION.md](DEV_INSTALLATION.md)).

## Kurzanleitung

1. *Create Instance* › **Haben**.
2. *Configuration › Haben › Öffentliche Adresse*, z. B. `https://haben.example.de`.
3. **Update** (der erste Lauf baut Haben, einige Minuten).
4. Reverse Proxy auf den Web-Port der Instanz (Vorgabe 3000).
5. **Start**. Die Konsole zeigt den Einrichtungscode für `https://…/setup`.

> [!IMPORTANT]
> `data/schluessel.env` enthält die beim ersten Lauf erzeugten Schlüssel (`HABEN_ENCRYPTION_KEY`,
> `BETTER_AUTH_SECRET`, Datenbank-Passwort, `RESTIC_PASSWORD`). Diese Datei zusätzlich an einem zweiten Ort
> sichern (Passwortmanager). Ohne `HABEN_ENCRYPTION_KEY` sind ELSTER-Zertifikat und API-Schlüssel nach einer
> Wiederherstellung nicht lesbar, ohne `RESTIC_PASSWORD` die restic-Sicherungen.

## Sicherung

### AMP-Backups (lokal und S3)

Die eingebauten AMP-Backups funktionieren mit dieser Instanz ganz normal, inklusive Zeitplan, S3 und Limits:

- *Configuration › Backups*: lokale Backups; unter *Cloud* „Use S3 Storage for Backups“ mit Service URL, Bucket,
  Access/Secret Key, *S3 Backup Count Limit* und *S3 Backup Space Limit* als Aufbewahrung.
- *Schedule*: Trigger anlegen (z. B. täglich 02:00) mit zwei Aufgaben: erst **Send console command `dump`**, dann
  **Backups › Take a backup** (mit S3).

Warum der Dump: Die Dateien einer laufenden Datenbank lassen sich nicht konsistent kopieren. Deshalb ist `pgdata/`
per `.backupExclude` ausgeschlossen, und jedes AMP-Backup enthält stattdessen `backups/haben-aktuell.sql.gz`.
Der Dump wird stündlich (*Haben › Sicherung › Dump-Intervall*), beim Stoppen und per Konsolenbefehl `dump`
erneuert; ein AMP-Backup einer gestoppten Instanz ist damit exakt.

**Wiederherstellen eines AMP-Backups**: in AMP wie gewohnt wiederherstellen und starten. Der Start erkennt am
Dump, dass Dateien zurückgespielt wurden, legt die bisherige Datenbank nach `alt/` und spielt den Dump ein.
Dasselbe passiert, wenn `pgdata/` fehlt (etwa bei einer neuen Instanz aus einem Backup).

### restic (zusätzlich, verschlüsselt, mit Aufbewahrung)

*Configuration › Haben › Sicherung*, wie der Backup-Container von Haben selbst:

| Einstellung | |
|---|---|
| Ziel | Aus, Lokal, S3 (AWS, Backblaze B2, Wasabi, MinIO, Hetzner …), SFTP, REST-Server |
| Uhrzeit | tägliche Sicherung (Vorgabe 03:15) |
| Aufbewahrung | täglich 14, wöchentlich 8, monatlich 24, jährlich 11 (GoBD: 10 Jahre) |
| Test-Restore | alle 7 Tage: Repository lesen, Dump in Wegwerf-Datenbank einspielen, Hash-Kette und Belege prüfen |

Gesichert werden ein vollständiger SQL-Dump und `data/belege/`. Das Ergebnis jeder Sicherung und jedes
Test-Restores zeigt Haben selbst an (Tabelle `backup_status`, Einstellungen › Export). Das restic-Passwort wird
erzeugt, falls keins eingetragen ist (`RESTIC_PASSWORD` in `data/schluessel.env`).

### Konsolenbefehle

| Befehl | |
|---|---|
| `dump` | Dump für AMP-Backups jetzt erneuern |
| `sicherung` | restic-Sicherung jetzt |
| `pruefung [id]` | Test-Restore (Standard: neuester Snapshot) |
| `snapshots` | restic-Stände anzeigen |
| `hilfe` | Befehle anzeigen |

### Wiederherstellen auf Anforderung

Instanz stoppen, im AMP-Dateimanager `haben/data/WIEDERHERSTELLEN` anlegen, eine Zeile hinein, starten:

| Inhalt | Stellt wieder her |
|---|---|
| `aktuell` | `backups/haben-aktuell.sql.gz` |
| `vor-update` | die letzte Sicherung vor einem Update (Update zurücknehmen: zusätzlich *Haben-Version* auf die alte setzen und *Update*) |
| `restic latest` / `restic <id>` | Datenbank **und Belege** aus restic |
| `<datei>.sql.gz` | eine Datei aus `backups/` oder `backups/vor-update/` |

Der bisherige Stand wandert nach `alt/`; scheitert das Einspielen, wird er unverändert zurückgelegt. Danach
heißt die Datei `WIEDERHERSTELLEN.erledigt-<Zeit>`.

## Datenbank-Schutz

Die eingebettete PostgreSQL ist von außen nicht erreichbar. Das wird bei jedem Start erzwungen:

- TCP nur auf `127.0.0.1` (Kommandozeile, schlägt `postgresql.conf` und `ALTER SYSTEM`); nach dem Start prüft das
  Skript `SHOW listen_addresses` und hält die Datenbank sofort an, falls sie anders lauscht.
- Der Datenbank-Port steht nicht in `habenports.json`: AMP gibt ihn weder in der Firewall frei noch leitet er ihn
  aus dem Container weiter.
- `pg_hba.conf` wird bei jedem Start neu geschrieben: nur Benutzer `haben`, nur lokal, nur mit Passwort
  (SCRAM-SHA-256, zufällig erzeugt), keine Replikation (`max_wal_senders=0`).
- Unix-Socket und Datenverzeichnis nur für den Instanz-Benutzer (`0700`).
- Haben selbst bekommt nur `DATABASE_URL`, nicht die Werkzeug-Variablen von PostgreSQL und keine Zugangsdaten der
  Sicherung.

Bei Datenbank „Extern“ liegt der Schutz bei der externen Datenbank (eigener Benutzer, `sslmode=require` in der
URL, kein öffentlicher Port).

## Einstellungen

- **Haben › Allgemein**: öffentliche Adresse, Zeitzone.
- **Haben › Datenbank**: eingebettet (Vorgabe) oder extern per URL, interner Port.
- **Haben › Sicherung**: Dump-Intervall für AMP-Backups, restic-Ziel, Zugangsdaten, Uhrzeit, Aufbewahrung, Test-Restore.
- **Haben › Schlüssel**: nur beim Umzug einer bestehenden Haben-Installation deren Schlüssel eintragen.
- **Haben › ELSTER**, **KI-Auslesung**, **Bank**, **Anmeldung per SSO**: wie in der
  [Haben-Doku](https://haben.app/installation.html).
- **Updates**: Haben-Version (leer = neuestes Release, sonst Tag wie `v0.6.6` oder Branch wie `main`),
  Repository, Bun-Version, Sicherung vor dem Update, Neu bauen.

Alles Weitere kommt als `NAME=Wert` in `data/haben.env` (hat Vorrang vor den AMP-Einstellungen).

## PostgreSQL-Upgrade

Die eingebettete Datenbank nutzt das PostgreSQL aus dem Container-Image. Fehlt nach einem neuen Image die alte
Major-Version, bricht der Start mit einem Hinweis ab. Dann `aktuell` in `data/WIEDERHERSTELLEN` schreiben und
starten: Der Dump vom letzten Stoppen wird in eine neue Datenbank der aktuellen Version eingespielt.

## Umzug einer bestehenden Haben-Installation

1. Alt: `docker compose exec db pg_dump -U haben haben | gzip > haben-umzug.sql.gz` und das Volume `belege` kopieren.
2. Instanz anlegen, in *Haben › Schlüssel* `AUTH_SECRET` und `ENCRYPTION_KEY` der alten `.env` eintragen, *Update*.
3. `haben-umzug.sql.gz` nach `backups/` und die Belege nach `data/belege/` hochladen, `haben-umzug.sql.gz` in
   `data/WIEDERHERSTELLEN` schreiben, starten.

## Entwicklung

AMP lädt aus einem Template nur die Manifest-Dateien. Die Logik steht in [`src/haben.sh`](src/haben.sh) und wird
von [`build.sh`](build.sh) base64-kodiert in `habenupdates.json` eingebettet. Nach jeder Änderung an `src/`:

```bash
./build.sh
```

Die CI (`.github/workflows/pruefen.yml`) prüft Syntax, ShellCheck, JSON und ob `habenupdates.json` aktuell ist.

| Datei | Inhalt |
|---|---|
| `haben.kvp` | Metadaten und Startkonfiguration der Instanz |
| `habenconfig.json` | Einstellungen in der AMP-Oberfläche |
| `habenports.json` | Web-Port (der Datenbank-Port bewusst nicht) |
| `habenupdates.json` | Update-Stufen (generiert, nicht von Hand ändern) |
| `habenmetaconfig.json` | leer, keine Konfigurationsdateien |
| `src/haben.sh` | Installation, Start/Stopp, Sicherung, Wiederherstellung |
| `src/habenupdates.template.json` | Vorlage für `habenupdates.json` |

Haben selbst steht unter AGPL-3.0 und wird nicht mitgeliefert, sondern bei jedem Update aus dem offiziellen
Repository gebaut.

#!/usr/bin/env bash
# amp-haben: Installation, Betrieb und Sicherung von Haben (https://github.com/firsttris/haben) in einer AMP-Instanz.
#
#   haben.sh install            Update-Stufe in AMP: Quellen holen, Bun installieren, bauen, Datenbank anlegen
#   haben.sh run                Start in AMP: Wiederherstellung (falls nötig), PostgreSQL, Migrationen, Haben
#   haben.sh dump               Lokalen Dump backups/haben-aktuell.sql.gz erneuern (für AMP-Backups)
#   haben.sh sicherung          restic-Sicherung jetzt (Dump + Belege, Aufbewahrung, Test-Restore wenn fällig)
#   haben.sh pruefung [id]      Test-Restore eines restic-Snapshots (Standard: neuester)
#   haben.sh snapshots          restic-Snapshots anzeigen
#
# Diese Datei ist die Quelle. AMP bekommt sie base64-kodiert über habenupdates.json (siehe build.sh).
# Alle Einstellungen kommen als Umgebungsvariablen aus AMP (haben.kvp, App.EnvironmentVariables und
# habenupdates.json); data/haben.env kann zusätzlich beliebige Variablen von Haben setzen.
#
# Sicherung auf zwei Ebenen:
#  - AMP-Backups (Lokal/S3, Aufbewahrung in AMP): pgdata/ ist per .backupExclude ausgeschlossen, weil sich die
#    Dateien einer laufenden Datenbank nicht konsistent kopieren lassen. Stattdessen liegt in jedem AMP-Backup
#    backups/haben-aktuell.sql.gz (stündlich, beim Stoppen und per Konsolenbefehl „dump“ erneuert). Nach dem
#    Wiederherstellen eines AMP-Backups erkennt der Start die abweichende Dump-Kennung und spielt den Dump ein.
#  - restic (Einstellungen › Sicherung): Dump und Belege verschlüsselt nach lokal, S3, SFTP oder REST, mit
#    Aufbewahrung und wöchentlichem Test-Restore, wie das haben-backup-Image von Haben.
set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="${HABEN_ROOT:?HABEN_ROOT fehlt}"
ROOT="${ROOT%/}"
APP="$ROOT/app"
WEB="$APP/apps/web"
DATA="$ROOT/data"
PG_DATA="$ROOT/pgdata"
RUN="$ROOT/run"
LOGS="$ROOT/logs"
BACKUPS="$ROOT/backups"
PREUPDATE="$BACKUPS/vor-update"
STATE="$ROOT/backup-state"
ALT="$ROOT/alt"
BUN_DIR="$ROOT/bun"
KEYS="$DATA/schluessel.env"
USER_ENV="$DATA/haben.env"
RESTORE_REQUEST="$DATA/WIEDERHERSTELLEN"
COMMIT_FILE="$ROOT/.haben-commit"
CURRENT_DUMP="$BACKUPS/haben-aktuell.sql.gz"
CURRENT_ID="$BACKUPS/haben-aktuell.id"
PG_MARKER="amp-haben-dump.id"
# Nur für Tests überschreibbar
PG_PREFIX="${HABEN_PG_PREFIX:-/usr/lib/postgresql}"

REPO="${HABEN_REPO:-}"
[ -n "$REPO" ] || REPO="https://github.com/firsttris/haben.git"
DB_MODE="${HABEN_DB_MODE:-}"
[ -n "$DB_MODE" ] || DB_MODE="embedded"
DB_PORT="${HABEN_DB_PORT:-}"
[ -n "$DB_PORT" ] || DB_PORT="54320"

export BUN_INSTALL="$BUN_DIR"
export BUN_INSTALL_CACHE_DIR="$ROOT/cache/bun"
export XDG_CACHE_HOME="$ROOT/cache"
export PATH="$BUN_DIR/bin:$PATH"

log() { echo "[amp-haben] $*"; }
die() {
  echo "[amp-haben] FEHLER: $*" >&2
  exit 1
}

ensure_dirs() {
  mkdir -p "$DATA/belege" "$DATA/eric" "$LOGS/eric" "$RUN" "$BACKUPS" "$PREUPDATE" "$STATE" "$ROOT/cache" "$ROOT/tmp"
  chmod 700 "$DATA" "$BACKUPS" "$STATE" 2> /dev/null || true
}

# Leere .backupExclude-Datei: AMP lässt das ganze Verzeichnis aus seinen Backups weg
exclude_dir() {
  if [ -d "$1" ] && [ ! -e "$1/.backupExclude" ]; then : > "$1/.backupExclude"; fi
}

ensure_excludes() {
  local d
  for d in "$APP" "$BUN_DIR" "$ROOT/cache" "$ROOT/tmp" "$RUN" "$STATE" "$ALT" "$ROOT/restic"; do
    exclude_dir "$d"
  done
  if [ -s "$PG_DATA/PG_VERSION" ]; then exclude_dir "$PG_DATA"; fi
}

rand_b64() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }
rand_hex() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Schlüssel beim ersten Lauf zufällig erzeugen; fehlende Einträge werden ergänzt, vorhandene nie geändert
ensure_keys() {
  local old_umask
  old_umask="$(umask)"
  umask 077
  [ -f "$KEYS" ] || {
    echo "# Von amp-haben erzeugt. Zusätzlich an einem zweiten Ort sichern (Passwortmanager)!"
    echo "# Ohne HABEN_ENCRYPTION_KEY sind ELSTER-Zertifikat und API-Schlüssel nach einer Wiederherstellung verloren,"
    echo "# ohne RESTIC_PASSWORD die restic-Sicherungen."
  } > "$KEYS"
  grep -q '^BETTER_AUTH_SECRET=' "$KEYS" || echo "BETTER_AUTH_SECRET=$(rand_b64)" >> "$KEYS"
  grep -q '^HABEN_ENCRYPTION_KEY=' "$KEYS" || {
    echo "HABEN_ENCRYPTION_KEY=$(rand_b64)" >> "$KEYS"
    log "Neue Schlüssel in $KEYS erzeugt. Bitte diese Datei zusätzlich sichern!"
  }
  grep -q '^HABEN_DB_PASSWORD=' "$KEYS" || echo "HABEN_DB_PASSWORD=$(rand_hex)" >> "$KEYS"
  grep -q '^RESTIC_PASSWORD=' "$KEYS" || echo "RESTIC_PASSWORD=$(rand_b64)" >> "$KEYS"
  umask "$old_umask"
}

load_keys() {
  set -a
  # shellcheck disable=SC1090
  . "$KEYS"
  set +a
  # Werte aus AMP haben Vorrang, etwa beim Umzug einer bestehenden Haben-Installation
  if [ -n "${HABEN_OVERRIDE_AUTH_SECRET:-}" ]; then export BETTER_AUTH_SECRET="$HABEN_OVERRIDE_AUTH_SECRET"; fi
  if [ -n "${HABEN_OVERRIDE_ENCRYPTION_KEY:-}" ]; then export HABEN_ENCRYPTION_KEY="$HABEN_OVERRIDE_ENCRYPTION_KEY"; fi
  if [ -n "${HABEN_BACKUP_PASSWORD:-}" ]; then export RESTIC_PASSWORD="$HABEN_BACKUP_PASSWORD"; fi
  unset HABEN_OVERRIDE_AUTH_SECRET HABEN_OVERRIDE_ENCRYPTION_KEY
}

load_user_env() {
  [ -f "$USER_ENV" ] || return 0
  log "Lade zusätzliche Einstellungen aus $USER_ENV"
  set -a
  # shellcheck disable=SC1090
  . "$USER_ENV"
  set +a
}

init_common() {
  ensure_dirs
  ensure_keys
  load_keys
}

need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" > /dev/null 2>&1 \
      || die "'$tool' fehlt. Die Instanz muss im AMP-Container laufen (Meta.ExtraContainerPackages in haben.kvp)."
  done
}

download() {
  if command -v curl > /dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$2" "$1"
  else
    wget -q -O "$2" "$1"
  fi
}

# Eine Sicherung zur Zeit (Dump, restic, Update). Ein Kindprozess, dessen Eltern die Sperre halten, setzt
# HABEN_LOCK_HELD=1 und wartet nicht auf sich selbst.
take_lock() {
  [ "${HABEN_LOCK_HELD:-0}" = 1 ] && return 0
  exec 9> "$RUN/sicherung.lock"
  flock -w "${HABEN_LOCK_WAIT:-3600}" 9 || die "Eine andere Sicherung läuft noch, abgebrochen."
}

new_id() { echo "$(date +%Y%m%d%H%M%S)-$(rand_hex | cut -c1-8)"; }

# ---------------------------------------------------------------- PostgreSQL

embedded() { [ "$DB_MODE" = "embedded" ]; }

db_url() { echo "${DATABASE_URL:-${HABEN_EXTERNAL_DATABASE_URL:-}}"; }

pg_latest_bin() {
  local v
  v="$(ls -1 "$PG_PREFIX" 2> /dev/null | sort -n | tail -n 1)"
  [ -n "$v" ] && [ -x "$PG_PREFIX/$v/bin/postgres" ] \
    || die "PostgreSQL ist nicht installiert. Die Instanz muss im AMP-Container laufen (Paket postgresql)."
  echo "$PG_PREFIX/$v/bin"
}

# PG_BIN passend zur Datenbank in pgdata (eingebettet) bzw. die neuesten Werkzeuge (extern).
# Mit „lenient“ gibt es bei fehlender alter Version die neueste statt eines Abbruchs (für die Wiederherstellung
# aus einem Dump, die zugleich der Weg auf eine neue PostgreSQL-Version ist).
PG_BIN=""
pg_bin() {
  local v
  if embedded && [ -s "$PG_DATA/PG_VERSION" ]; then
    v="$(cat "$PG_DATA/PG_VERSION")"
    if [ -x "$PG_PREFIX/$v/bin/postgres" ]; then
      PG_BIN="$PG_PREFIX/$v/bin"
    elif [ "${1:-}" = lenient ]; then
      PG_BIN="$(pg_latest_bin)"
    else
      die "Die Datenbank in $PG_DATA stammt von PostgreSQL $v, im Container gibt es aber nur: $(ls "$PG_PREFIX" 2> /dev/null | tr '\n' ' '). Upgrade: 'aktuell' in data/WIEDERHERSTELLEN schreiben und neu starten (README, PostgreSQL-Upgrade)."
    fi
  else
    PG_BIN="$(pg_latest_bin)"
  fi
  if embedded; then
    export PGHOST="$RUN" PGPORT="$DB_PORT" PGUSER="haben" PGPASSWORD="$HABEN_DB_PASSWORD"
  fi
}

pg_init() {
  [ -s "$PG_DATA/PG_VERSION" ] && return 0
  [ -z "$(ls -A "$PG_DATA" 2> /dev/null)" ] || die "$PG_DATA ist nicht leer, enthält aber keine Datenbank."
  pg_bin
  mkdir -p "$PG_DATA"
  chmod 700 "$PG_DATA"
  local pwfile
  pwfile="$(mktemp "$ROOT/tmp/pw.XXXXXX")"
  printf '%s\n' "$HABEN_DB_PASSWORD" > "$pwfile"
  log "Lege die Datenbank an (PostgreSQL $(basename "$(dirname "$PG_BIN")")) …"
  if ! "$PG_BIN/initdb" -D "$PG_DATA" -U haben --pwfile="$pwfile" --auth=scram-sha-256 -E UTF8 --locale=C.UTF-8 \
    > "$LOGS/initdb.log" 2>&1; then
    rm -f "$pwfile"
    tail -n 30 "$LOGS/initdb.log" >&2
    die "initdb fehlgeschlagen"
  fi
  rm -f "$pwfile"
  exclude_dir "$PG_DATA"
}

# Nach einem harten Abbruch des Containers kann postmaster.pid auf eine fremde PID zeigen
pg_clear_stale_pid() {
  local f="$PG_DATA/postmaster.pid" pid
  [ -f "$f" ] || return 0
  pid="$(head -n 1 "$f")"
  if [ -n "$pid" ] && [ -r "/proc/$pid/comm" ] && grep -q postgres "/proc/$pid/comm"; then return 0; fi
  log "Entferne veraltete postmaster.pid (PID $pid)"
  rm -f "$f"
}

pg_running() {
  [ -s "$PG_DATA/PG_VERSION" ] || return 1
  pg_clear_stale_pid
  "$PG_BIN/pg_ctl" -D "$PG_DATA" status > /dev/null 2>&1
}

# Kein Zugriff von außen, bei jedem Start erzwungen (Änderungen an pg_hba.conf werden überschrieben):
#  - TCP nur auf 127.0.0.1 (Kommandozeile schlägt postgresql.conf und ALTER SYSTEM), der Port steht nicht in
#    habenports.json, AMP gibt ihn also weder frei noch leitet ihn weiter
#  - Unix-Socket nur für den Instanz-Benutzer (0700, Verzeichnis run/ 0700)
#  - nur der Benutzer haben, nur mit Passwort (SCRAM-SHA-256, zufällig, 48 Hex-Zeichen), keine Replikation
pg_harden() {
  local old_umask
  old_umask="$(umask)"
  umask 077
  cat > "$PG_DATA/pg_hba.conf" << 'EOF'
# Von amp-haben bei jedem Start geschrieben, Änderungen gehen verloren.
# Nur lokal, nur Benutzer haben, nur mit Passwort (SCRAM). Kein Zugriff aus dem Netz, keine Replikation.
# TYPE  DATABASE  USER   ADDRESS        METHOD
local   all       haben                 scram-sha-256
host    all       haben  127.0.0.1/32   scram-sha-256
EOF
  umask "$old_umask"
  chmod 700 "$PG_DATA" "$RUN"
}

PG_OPTS=""
pg_start_opts() {
  PG_OPTS="-p $DB_PORT -k '$RUN' -c listen_addresses=127.0.0.1 -c unix_socket_permissions=0700"
  PG_OPTS="$PG_OPTS -c password_encryption=scram-sha-256 -c ssl=off -c max_wal_senders=0 -c wal_level=minimal"
}

# Nach dem Start: läuft PostgreSQL wirklich nur lokal? Sonst sofort wieder anhalten.
pg_verify_local() {
  local listen
  listen="$("$PG_BIN/psql" -X -d postgres -tAc "SHOW listen_addresses" 2> /dev/null || true)"
  if [ "$listen" != "127.0.0.1" ]; then
    "$PG_BIN/pg_ctl" -D "$PG_DATA" -m fast -w stop > /dev/null 2>&1 || true
    die "PostgreSQL lauscht auf '$listen' statt nur auf 127.0.0.1; aus Sicherheitsgründen angehalten."
  fi
}

PG_STARTED=0
pg_start() {
  if pg_running; then
    PG_STARTED=0
    return 0
  fi
  mkdir -p "$RUN"
  pg_harden
  pg_start_opts
  if ! "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$LOGS/postgresql.log" -w -t 300 -o "$PG_OPTS" start > /dev/null; then
    tail -n 30 "$LOGS/postgresql.log" >&2
    die "PostgreSQL startet nicht (Protokoll: $LOGS/postgresql.log)"
  fi
  PG_STARTED=1
  pg_verify_local
}

pg_stop() {
  pg_running || return 0
  "$PG_BIN/pg_ctl" -D "$PG_DATA" -m fast -w -t 120 stop > /dev/null || log "PostgreSQL ließ sich nicht sauber beenden"
}

pg_ensure_db() {
  local exists
  exists="$("$PG_BIN/psql" -X -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'haben'")"
  [ "$exists" = 1 ] || "$PG_BIN/createdb" -O haben haben
}

# Datenbank für eine Sicherung erreichbar machen; eine gestoppte eingebettete Datenbank wird kurz gestartet
DB_OPENED=0
db_open() {
  pg_bin
  if embedded; then
    [ -s "$PG_DATA/PG_VERSION" ] || die "Es gibt noch keine Datenbank (erst Update und Start ausführen)."
    pg_start
    DB_OPENED="$PG_STARTED"
    pg_ensure_db
  else
    [ -n "$(db_url)" ] || die "Datenbank-Modus 'extern', aber keine Datenbank-URL eingetragen."
  fi
}

db_close() {
  if embedded && [ "$DB_OPENED" = 1 ]; then
    pg_stop
    DB_OPENED=0
  fi
}

# psql auf die Datenbank von Haben (HPSQL_DB: eine andere Datenbank im selben eingebetteten Cluster)
hpsql() {
  if embedded; then
    "$PG_BIN/psql" -X -d "${HPSQL_DB:-haben}" "$@"
  else
    "$PG_BIN/psql" -X -d "$(db_url)" "$@"
  fi
}

check_dump() {
  gunzip -c "$1" 2> /dev/null | tail -n 20 | grep "PostgreSQL database dump complete" > /dev/null
}

# Vollständiger SQL-Dump (gzip) nach $1; ein abgebrochener Dump ersetzt nie einen guten
dump_to() {
  local out="$1" tmp="$1.tmp"
  mkdir -p "$(dirname "$out")"
  if embedded; then
    "$PG_BIN/pg_dump" -d haben | gzip > "$tmp" || {
      rm -f "$tmp"
      die "pg_dump fehlgeschlagen"
    }
  else
    "$PG_BIN/pg_dump" -d "$(db_url)" | gzip > "$tmp" || {
      rm -f "$tmp"
      die "pg_dump fehlgeschlagen"
    }
  fi
  check_dump "$tmp" || {
    rm -f "$tmp"
    die "Dump unvollständig oder beschädigt"
  }
  mv -f "$tmp" "$out"
}

prune_files() {
  local pattern="$1" keep="$2"
  # shellcheck disable=SC2086
  ls -1t $pattern 2> /dev/null | tail -n +"$((keep + 1))" | xargs -r rm -f || true
}

# Spielt einen Dump in eine frische eingebettete Datenbank ein. Die bisherige wandert nach alt/.
restore_db_from() {
  local file="$1" reason="$2" stamp moved=""
  embedded || die "Wiederherstellen geht nur mit der eingebetteten Datenbank."
  [ -f "$file" ] || die "Dump $file gibt es nicht."
  check_dump "$file" || die "Dump $file ist unvollständig oder beschädigt; nichts geändert."
  log "Stelle die Datenbank aus $file wieder her ($reason) …"
  pg_bin lenient
  pg_stop
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [ -n "$(ls -A "$PG_DATA" 2> /dev/null)" ]; then
    mkdir -p "$ALT"
    exclude_dir "$ALT"
    moved="$ALT/pgdata-$stamp"
    mv "$PG_DATA" "$moved"
    log "Bisherige Datenbank verschoben nach $moved (nach Prüfung von Hand löschen)"
  fi
  rm -rf "$PG_DATA"
  pg_init
  pg_start
  if ! "$PG_BIN/createdb" -O haben haben \
    || ! gunzip -c "$file" | "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -d haben > "$LOGS/wiederherstellung.log" 2>&1; then
    tail -n 20 "$LOGS/wiederherstellung.log" >&2 || true
    pg_stop
    rm -rf "$PG_DATA"
    if [ -n "$moved" ]; then mv "$moved" "$PG_DATA"; fi
    die "Wiederherstellung fehlgeschlagen; der bisherige Stand ist unverändert zurückgelegt."
  fi
  # Der eingespielte Stand ist ab jetzt der aktuelle Dump mit eigener Kennung
  if [ "$file" != "$CURRENT_DUMP" ]; then
    cp -f "$file" "$CURRENT_DUMP.tmp"
    mv -f "$CURRENT_DUMP.tmp" "$CURRENT_DUMP"
    new_id > "$CURRENT_ID"
  fi
  [ -s "$CURRENT_ID" ] || new_id > "$CURRENT_ID"
  cp -f "$CURRENT_ID" "$PG_DATA/$PG_MARKER"
  log "Datenbank wiederhergestellt."
}

# Vor dem Start: angeforderte Wiederherstellung (data/WIEDERHERSTELLEN) oder ein zurückgespieltes AMP-Backup
restore_if_needed() {
  local cmd="" arg="" f
  if [ -f "$RESTORE_REQUEST" ]; then
    read -r cmd arg _ < "$RESTORE_REQUEST" || true
    cmd="${cmd//$'\r'/}"
    arg="${arg//$'\r'/}"
    case "$cmd" in
      "" | aktuell) restore_db_from "$CURRENT_DUMP" "angefordert in $RESTORE_REQUEST" ;;
      vor-update)
        f="$(ls -1t "$PREUPDATE"/*.sql.gz 2> /dev/null | sed -n 1p || true)"
        [ -n "$f" ] || die "Es gibt keine Sicherung vor einem Update in $PREUPDATE."
        restore_db_from "$f" "angefordert in $RESTORE_REQUEST"
        ;;
      restic) restic_restore "${arg:-latest}" ;;
      *)
        f="$cmd"
        [ -f "$f" ] || f="$BACKUPS/$cmd"
        [ -f "$f" ] || f="$PREUPDATE/$cmd"
        [ -f "$f" ] || die "In $RESTORE_REQUEST steht '$cmd'. Erlaubt: aktuell, vor-update, restic [id] oder ein Dateiname aus backups/."
        restore_db_from "$f" "angefordert in $RESTORE_REQUEST"
        ;;
    esac
    mv -f "$RESTORE_REQUEST" "$RESTORE_REQUEST.erledigt-$(date +%Y%m%d-%H%M%S)"
    return 0
  fi
  if [ ! -s "$PG_DATA/PG_VERSION" ] && [ -f "$CURRENT_DUMP" ]; then
    restore_db_from "$CURRENT_DUMP" "keine Datenbank vorhanden, etwa nach Wiederherstellung eines AMP-Backups"
  elif [ -s "$PG_DATA/$PG_MARKER" ] && [ -s "$CURRENT_ID" ] && [ "$(cat "$PG_DATA/$PG_MARKER")" != "$(cat "$CURRENT_ID")" ]; then
    restore_db_from "$CURRENT_DUMP" "AMP-Backup wurde wiederhergestellt: der Dump in backups/ passt nicht zur Datenbank"
  fi
}

# ---------------------------------------------------------------- restic

RESTIC_OPTS=()
rs() { restic "${RESTIC_OPTS[@]}" "$@"; }

# Repository aus den AMP-Einstellungen; Rückgabe 1, wenn keine restic-Sicherung eingerichtet ist
restic_env() {
  local target="${HABEN_BACKUP_TARGET:-off}" path endpoint
  case "$target" in
    "" | off) return 1 ;;
    local)
      path="${HABEN_BACKUP_LOCAL_PATH:-}"
      [ -n "$path" ] || path="$ROOT/restic"
      export RESTIC_REPOSITORY="$path"
      ;;
    s3)
      endpoint="${HABEN_BACKUP_S3_ENDPOINT:-}"
      [ -n "$endpoint" ] && [ -n "${HABEN_BACKUP_S3_BUCKET:-}" ] || die "Sicherung S3: Endpunkt und Bucket eintragen."
      [ -n "${HABEN_BACKUP_S3_ACCESS_KEY:-}" ] && [ -n "${HABEN_BACKUP_S3_SECRET_KEY:-}" ] || die "Sicherung S3: Access Key und Secret Key eintragen."
      export RESTIC_REPOSITORY="s3:${endpoint%/}/${HABEN_BACKUP_S3_BUCKET}${HABEN_BACKUP_S3_PREFIX:+/${HABEN_BACKUP_S3_PREFIX#/}}"
      export AWS_ACCESS_KEY_ID="$HABEN_BACKUP_S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$HABEN_BACKUP_S3_SECRET_KEY"
      if [ -n "${HABEN_BACKUP_S3_REGION:-}" ]; then export AWS_DEFAULT_REGION="$HABEN_BACKUP_S3_REGION"; fi
      ;;
    sftp | rest)
      [ -n "${HABEN_BACKUP_REPOSITORY:-}" ] || die "Sicherung $target: Repository-Adresse eintragen."
      case "$HABEN_BACKUP_REPOSITORY" in "$target":*) ;; *) die "Die Repository-Adresse muss mit '$target:' beginnen." ;; esac
      export RESTIC_REPOSITORY="$HABEN_BACKUP_REPOSITORY"
      if [ "$target" = sftp ]; then
        [ -f "$DATA/ssh/id_ed25519" ] || die "Sicherung SFTP: privaten SSH-Schlüssel als data/ssh/id_ed25519 hochladen."
        chmod 600 "$DATA/ssh/id_ed25519"
        RESTIC_OPTS=(-o "sftp.args=-i $DATA/ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$DATA/ssh/known_hosts")
      fi
      ;;
    *) die "Unbekanntes Sicherungsziel '$target'" ;;
  esac
  [ -n "${RESTIC_PASSWORD:-}" ] || die "Kein restic-Passwort (data/schluessel.env oder Einstellung)."
  export RESTIC_PASSWORD RESTIC_CACHE_DIR="$ROOT/cache/restic"
  BACKUP_HOST="${HABEN_BACKUP_HOST:-}"
  [ -n "$BACKUP_HOST" ] || BACKUP_HOST="haben"
  need restic
}

# Ergebnis in die Tabelle backup_status von Haben (Einstellungen › Export, Hinweis in der Übersicht)
status_table() {
  [ "$(hpsql -At -c "SELECT to_regclass('public.backup_status') IS NOT NULL" 2> /dev/null)" = t ]
}

record_status() {
  status_table || return 0
  hpsql -q -v ON_ERROR_STOP=1 -v kind="$1" -v ok="$2" -v snapshot="$3" -v bytes="$4" -v message="$5" > /dev/null <<'SQL' \
    || log "Ergebnis konnte nicht in backup_status eingetragen werden."
INSERT INTO backup_status (kind, ok, snapshot, bytes, message)
VALUES (:'kind', :'ok'::boolean, nullif(:'snapshot', ''), nullif(:'bytes', '')::bigint, :'message');
SQL
}

last_error() {
  [ -s "$1" ] || {
    echo "Abgebrochen ohne Meldung"
    return
  }
  grep -v '^[[:space:]]*$' "$1" | tail -n 3 \
    | sed 's/^{"message_type":"exit_error".*"message":"\(.*\)"}$/\1/' \
    | tr '\n' ' ' | sed 's/ *$//' | cut -c1-500
}

ERRLOG=""
TEE_PID=""
capture_errors() {
  ERRLOG="$1"
  : > "$ERRLOG"
  exec 3>&2 2> >(tee -a "$ERRLOG" >&3)
  TEE_PID=$!
}
release_errors() {
  exec 2>&3
  wait "$TEE_PID" 2> /dev/null || true
}

keep_args() {
  local n v any=0
  KEEP=()
  for n in daily weekly monthly yearly; do
    v="HABEN_BACKUP_KEEP_${n^^}"
    v="${!v:-}"
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    if [ "$v" -gt 0 ]; then
      KEEP+=("--keep-$n" "$v")
      any=1
    fi
  done
  [ "$any" = 1 ]
}

cmd_sicherung() {
  init_common
  restic_env || die "Keine restic-Sicherung eingerichtet (Einstellungen › Sicherung › Ziel)."
  need flock gzip
  take_lock
  local dump="$STATE/dump/haben.sql.gz" summary snapshot bytes files days due=false
  BACKUP_OK=0
  capture_errors "$STATE/sicherung.err"
  trap 'sicherung_finish $?' EXIT
  log "restic-Sicherung nach $RESTIC_REPOSITORY …"

  local rc=0 err
  err="$(rs cat config 2>&1 > /dev/null)" || rc=$?
  if [ "$rc" = 10 ]; then
    log "Lege das restic-Repository an …"
    rs init > /dev/null
  elif [ "$rc" != 0 ]; then
    echo "$err" >&2
    exit 1
  fi

  db_open
  dump_to "$dump"
  summary="$(rs backup --json --retry-lock 10m --host "$BACKUP_HOST" --tag haben "$dump" "$DATA/belege" | grep '"message_type":"summary"')"
  snapshot="$(sed -n 's/.*"snapshot_id":"\([0-9a-f]\{8\}\)[0-9a-f]*".*/\1/p' <<< "$summary")"
  bytes="$(sed -n 's/.*"total_bytes_processed":\([0-9]*\).*/\1/p' <<< "$summary")"
  files="$(sed -n 's/.*"total_files_processed":\([0-9]*\).*/\1/p' <<< "$summary")"
  [ -n "$snapshot" ] || die "restic hat keinen Snapshot gemeldet."
  log "Snapshot $snapshot: ${files:-?} Dateien, ${bytes:-?} Byte"
  if keep_args; then
    rs forget --retry-lock 10m --tag haben --host "$BACKUP_HOST" --group-by host,tags "${KEEP[@]}" --prune > /dev/null
    log "Aufbewahrung angewendet: ${KEEP[*]}"
  else
    log "WARNUNG: keine Aufbewahrung eingestellt, alte Snapshots bleiben alle erhalten."
  fi
  record_status backup true "$snapshot" "$bytes" "${files:-?} Dateien, AMP-Instanz"
  BACKUP_OK=1

  days="${HABEN_RESTORE_CHECK_DAYS:-7}"
  [[ "$days" =~ ^[0-9]{1,4}$ ]] || days=7
  days=$((10#$days))
  if [ "$days" != 0 ] && embedded; then
    if status_table; then
      due="$(hpsql -At -c "SELECT NOT EXISTS (SELECT 1 FROM backup_status WHERE kind = 'restore_check'
        AND at > now() - interval '1 day' * $days + interval '12 hours')" 2> /dev/null || echo f)"
    elif [ "$(date +%u)" = 7 ]; then
      due=t
    fi
  fi
  if [ "$due" = t ]; then
    HABEN_LOCK_HELD=1 bash "$SELF" pruefung "$snapshot" || log "Test-Restore fehlgeschlagen; die Sicherung selbst ist erfolgreich."
  fi
}

sicherung_finish() {
  local rc="$1"
  trap - EXIT
  release_errors
  rm -f "$STATE/dump/haben.sql.gz" "$STATE/dump/haben.sql.gz.tmp"
  if [ "$rc" != 0 ] && [ "$BACKUP_OK" != 1 ]; then
    record_status backup false "" "" "$(last_error "$ERRLOG")" || true
    echo "fehler $(date -Iseconds)" > "$STATE/status"
    log "restic-Sicherung FEHLGESCHLAGEN: $(last_error "$ERRLOG")"
  else
    echo "ok $(date -Iseconds)" > "$STATE/status"
  fi
  db_close || true
  exit "$rc"
}

# Test-Restore wie restore-check.sh von Haben: Daten im Repository lesen, Dump in eine Wegwerf-Datenbank
# einspielen, Hash-Kette, Siegel und eine Stichprobe der Belege prüfen, nichts ersetzen
cmd_pruefung() {
  init_common
  restic_env || die "Keine restic-Sicherung eingerichtet."
  embedded || die "Der Test-Restore braucht die eingebettete Datenbank."
  need flock gzip sha256sum
  take_lock
  local snapshot="${1:-latest}" subset="${HABEN_RESTORE_CHECK_SUBSET:-5%}" samples="${HABEN_RESTORE_CHECK_FILES:-20}"
  CHECK_DB="haben_restore_check_$(date +%Y%m%d%H%M%S)_$RANDOM"
  CHECK_WORK="$(mktemp -d "$ROOT/tmp/pruefung.XXXXXX")"
  CHECK_OK=0
  CHECK_MESSAGE=""
  CHECK_SNAPSHOT="$snapshot"
  capture_errors "$CHECK_WORK/fehler.log"
  trap 'pruefung_finish $?' EXIT
  export PGOPTIONS="-c client_min_messages=warning"
  db_open

  log "Test-Restore: prüfe das Repository ($subset der Daten) …"
  rs check --retry-lock 10m --read-data-subset "$subset" > /dev/null
  local filters=() path root seq hash live_hash tables summary problems checked=0 sha actual
  [ "$snapshot" != latest ] || filters=(--host "$BACKUP_HOST" --tag haben)
  snapshot="$(rs snapshots --json "${filters[@]}" "$snapshot" | grep -o '"short_id":"[0-9a-f]*"' | tail -n 1 | cut -d'"' -f4 || true)"
  [ -n "$snapshot" ] || die "Kein Snapshot ${1:-latest} für Host $BACKUP_HOST gefunden."
  CHECK_SNAPSHOT="$snapshot"
  path="$(rs ls --json "$snapshot" | grep -o '"path":"[^"]*/backup-state/dump/haben.sql.gz"' | sed -n 1p | cut -d'"' -f4 || true)"
  [ -n "$path" ] || die "Snapshot $snapshot enthält keinen Dump von amp-haben."
  root="${path%/backup-state/dump/haben.sql.gz}"
  rs dump "$snapshot" "$path" > "$CHECK_WORK/haben.sql.gz"
  check_dump "$CHECK_WORK/haben.sql.gz" || die "Der Dump in Snapshot $snapshot ist unvollständig oder beschädigt."
  "$PG_BIN/createdb" -O haben "$CHECK_DB"
  gunzip -c "$CHECK_WORK/haben.sql.gz" | HPSQL_DB="$CHECK_DB" hpsql -v ON_ERROR_STOP=1 --quiet > /dev/null \
    || die "Der Dump aus Snapshot $snapshot ließ sich nicht einspielen."
  rm -f "$CHECK_WORK/haben.sql.gz"

  tables="$(HPSQL_DB="$CHECK_DB" hpsql -At -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")"
  [ "$tables" -gt 0 ] || die "Der Dump aus Snapshot $snapshot enthält keine Tabellen."
  summary="$tables Tabellen"

  if [ "$(HPSQL_DB="$CHECK_DB" hpsql -At -c "SELECT to_regprocedure('haben_integrity_problems(integer)') IS NOT NULL")" = t ]; then
    problems="$(HPSQL_DB="$CHECK_DB" hpsql -At -F ': ' -c "SELECT tabelle, befund FROM haben_integrity_problems(5)")"
    [ -z "$problems" ] || die "Hash-Kette oder Siegel im Backup beschädigt: $(head -n 3 <<< "$problems" | tr '\n' ' ')"
    read -r seq hash <<< "$(HPSQL_DB="$CHECK_DB" hpsql -At -F ' ' -c "SELECT seq, encode(hash, 'hex') FROM audit_chain")"
    [ -n "${seq:-}" ] || die "Im Backup fehlt der Kopf der Kette (audit_chain)."
    live_hash="$(hpsql -At -v seq="$seq" <<< "SELECT encode(row_hash, 'hex') FROM audit_log WHERE seq = :'seq'")"
    [ -n "$live_hash" ] || die "Eintrag Nr. $seq aus dem Backup fehlt in der laufenden Datenbank."
    [ "$live_hash" = "$hash" ] || die "Eintrag Nr. $seq hat im Backup einen anderen Hash als in der laufenden Datenbank."
    summary="$summary, Kette bis Nr. $seq geprüft und gleich der laufenden Datenbank"
  fi

  if [[ "$samples" =~ ^[0-9]{1,4}$ ]] && [ "$samples" != 0 ] \
    && [ "$(HPSQL_DB="$CHECK_DB" hpsql -At -c "SELECT to_regclass('public.documents') IS NOT NULL")" = t ]; then
    while read -r sha; do
      [ -n "$sha" ] || continue
      actual="$(rs dump "$snapshot" "$root/data/belege/${sha:0:2}/$sha" | sha256sum | cut -d' ' -f1)" \
        || die "Beleg $sha fehlt im Snapshot $snapshot."
      [ "$actual" = "$sha" ] || die "Beleg $sha im Snapshot $snapshot hat eine andere Prüfsumme ($actual)."
      checked=$((checked + 1))
    done <<< "$(HPSQL_DB="$CHECK_DB" hpsql -At -c "SELECT sha256 FROM (SELECT sha256 FROM documents UNION SELECT sha256 FROM archive_files) f
      ORDER BY random() LIMIT $samples" 2> /dev/null || true)"
    summary="$summary, $checked Belege"
  fi
  CHECK_MESSAGE="$summary, $subset der Daten gelesen"
  CHECK_OK=1
}

pruefung_finish() {
  local rc="$1"
  trap - EXIT
  release_errors
  "$PG_BIN/dropdb" --if-exists "$CHECK_DB" 2> /dev/null || log "Wegwerf-Datenbank $CHECK_DB ließ sich nicht löschen."
  if [ "$rc" = 0 ] && [ "$CHECK_OK" = 1 ]; then
    record_status restore_check true "$CHECK_SNAPSHOT" "" "$CHECK_MESSAGE"
    log "Test-Restore bestanden: $CHECK_MESSAGE"
  else
    record_status restore_check false "$CHECK_SNAPSHOT" "" "$(last_error "$ERRLOG")" || true
    log "Test-Restore FEHLGESCHLAGEN: $(last_error "$ERRLOG")"
  fi
  rm -rf "$CHECK_WORK"
  db_close || true
  exit "$rc"
}

# Datenbank und Belege aus einem restic-Snapshot (beim Start über data/WIEDERHERSTELLEN: restic <id|latest>)
restic_restore() {
  local snapshot="$1" work dump belege stamp
  restic_env || die "Keine restic-Sicherung eingerichtet; Wiederherstellen aus restic geht nicht."
  work="$(mktemp -d "$ROOT/tmp/wiederherstellung.XXXXXX")"
  log "Hole restic-Snapshot $snapshot aus $RESTIC_REPOSITORY …"
  rs restore "$snapshot" --host "$BACKUP_HOST" --tag haben --target "$work" > /dev/null
  dump="$(find "$work" -type f -path '*/backup-state/dump/haben.sql.gz' | sed -n 1p)"
  [ -n "$dump" ] || die "Snapshot $snapshot enthält keinen Dump von amp-haben."
  belege="${dump%/backup-state/dump/haben.sql.gz}/data/belege"
  restore_db_from "$dump" "restic-Snapshot $snapshot"
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$ALT"
  exclude_dir "$ALT"
  if [ -d "$DATA/belege" ]; then mv "$DATA/belege" "$ALT/belege-$stamp"; fi
  if [ -d "$belege" ]; then mv "$belege" "$DATA/belege"; else mkdir -p "$DATA/belege"; fi
  log "Belege wiederhergestellt; die bisherigen liegen in $ALT/belege-$stamp."
  rm -rf "$work"
}

cmd_snapshots() {
  init_common
  restic_env || die "Keine restic-Sicherung eingerichtet."
  rs snapshots --tag haben
}

cmd_dump() {
  init_common
  need flock gzip
  take_lock
  db_open
  dump_to "$CURRENT_DUMP"
  new_id > "$CURRENT_ID"
  if embedded; then cp -f "$CURRENT_ID" "$PG_DATA/$PG_MARKER"; fi
  [ "${HABEN_QUIET:-0}" = 1 ] || log "Lokaler Dump erneuert: $CURRENT_DUMP ($(du -h "$CURRENT_DUMP" | cut -f1))"
  db_close
}

# ---------------------------------------------------------------- Quellen, Bun, Build

resolve_version() {
  local v="${HABEN_VERSION:-}"
  case "$v" in
    "" | latest)
      TARGET="$(git -C "$APP" tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
      [ -n "$TARGET" ] || die "Kein Release-Tag in $REPO gefunden"
      TARGET_REF="refs/tags/$TARGET"
      ;;
    *)
      if git -C "$APP" rev-parse -q --verify "refs/tags/$v^{commit}" > /dev/null; then
        TARGET="$v" TARGET_REF="refs/tags/$v"
      elif git -C "$APP" rev-parse -q --verify "refs/tags/v$v^{commit}" > /dev/null; then
        TARGET="v$v" TARGET_REF="refs/tags/v$v"
      elif git -C "$APP" rev-parse -q --verify "refs/remotes/origin/$v^{commit}" > /dev/null; then
        TARGET="$v" TARGET_REF="refs/remotes/origin/$v"
      else
        die "Version '$v' gibt es in $REPO nicht (weder Tag noch Branch)"
      fi
      ;;
  esac
  NEW_COMMIT="$(git -C "$APP" rev-parse "$TARGET_REF^{commit}")"
}

fetch_sources() {
  if [ ! -d "$APP/.git" ]; then
    log "Lade Haben aus $REPO …"
    rm -rf "$APP"
    git clone --quiet --no-checkout "$REPO" "$APP"
  fi
  git -C "$APP" remote set-url origin "$REPO"
  git -C "$APP" fetch --quiet --force --prune --tags origin '+refs/heads/*:refs/remotes/origin/*'
  resolve_version
  OLD_COMMIT="$(cat "$COMMIT_FILE" 2> /dev/null || true)"
}

checkout_sources() {
  if [ "$(git -C "$APP" rev-parse -q --verify HEAD 2> /dev/null || true)" != "$NEW_COMMIT" ]; then
    git -C "$APP" -c advice.detachedHead=false checkout --quiet --force --detach "$NEW_COMMIT"
  fi
  # Eigene Änderungen und alte Build-Ergebnisse weg; node_modules bleibt als Cache
  git -C "$APP" reset --quiet --hard "$NEW_COMMIT"
  if [ "$NEW_COMMIT" != "$OLD_COMMIT" ]; then git -C "$APP" clean -ffdxq -e node_modules -e .backupExclude; fi
}

install_bun() {
  local want have target tmp
  want="${HABEN_BUN_VERSION:-}"
  want="${want#v}"
  [ -n "$want" ] || want="$(sed -n 's/.*"packageManager": *"bun@\([0-9][0-9.]*\)".*/\1/p' "$APP/package.json" | head -n 1)"
  [ -n "$want" ] || die "Bun-Version nicht ermittelbar (packageManager in package.json)"
  have=""
  if [ -x "$BUN_DIR/bin/bun" ]; then have="$("$BUN_DIR/bin/bun" --version 2> /dev/null || true)"; fi
  if [ "$have" = "$want" ]; then
    log "Bun $want ist installiert"
    return 0
  fi
  case "$(uname -m)" in
    x86_64 | amd64)
      target="linux-x64"
      grep -q avx2 /proc/cpuinfo || target="linux-x64-baseline"
      ;;
    aarch64 | arm64) target="linux-aarch64" ;;
    *) die "Nicht unterstützte Architektur: $(uname -m)" ;;
  esac
  log "Installiere Bun $want ($target) …"
  tmp="$(mktemp -d "$ROOT/tmp/bun.XXXXXX")"
  download "https://github.com/oven-sh/bun/releases/download/bun-v$want/bun-$target.zip" "$tmp/bun.zip" \
    || die "Download von Bun $want fehlgeschlagen"
  unzip -oq "$tmp/bun.zip" -d "$tmp"
  mkdir -p "$BUN_DIR/bin"
  mv -f "$tmp/bun-$target/bun" "$BUN_DIR/bin/bun"
  chmod 755 "$BUN_DIR/bin/bun"
  rm -rf "$tmp"
}

build_app() {
  if [ "$NEW_COMMIT" = "$OLD_COMMIT" ] && [ -f "$WEB/.output/server/index.mjs" ] && [ "${HABEN_FORCE_REBUILD:-false}" != "true" ]; then
    log "Haben $TARGET ist bereits gebaut"
    return 0
  fi
  log "Installiere Abhängigkeiten …"
  (cd "$APP" && bun install --frozen-lockfile)
  log "Baue Haben $TARGET (dauert ein paar Minuten) …"
  (cd "$APP" && bun run build)
  [ -f "$WEB/.output/server/index.mjs" ] || die "Build ohne Ergebnis ($WEB/.output/server/index.mjs fehlt)"
  echo "$NEW_COMMIT" > "$COMMIT_FILE"
}

# ---------------------------------------------------------------- Befehle

cmd_install() {
  need git unzip base64 od flock gzip
  init_common
  take_lock
  fetch_sources
  log "Ziel: Haben $TARGET (${NEW_COMMIT:0:12}), installiert: ${OLD_COMMIT:0:12}"

  # Migrationen lassen sich nicht zurückspielen: vor jedem Versionswechsel sichern (die letzten 10 bleiben)
  if embedded && [ -n "$OLD_COMMIT" ] && [ "$OLD_COMMIT" != "$NEW_COMMIT" ] && [ -s "$PG_DATA/PG_VERSION" ] \
    && [ "${HABEN_PRE_UPDATE_BACKUP:-true}" != "false" ]; then
    local old_tag
    old_tag="$(git -C "$APP" describe --tags --always "$OLD_COMMIT" 2> /dev/null || echo "${OLD_COMMIT:0:12}")"
    db_open
    dump_to "$PREUPDATE/haben-$(date +%Y%m%d-%H%M%S)-$old_tag.sql.gz"
    log "Datenbank vor dem Update gesichert ($PREUPDATE)"
    prune_files "$PREUPDATE/haben-*.sql.gz" 10
    db_close
  fi

  checkout_sources
  install_bun
  build_app

  if embedded && [ ! -f "$CURRENT_DUMP" ]; then pg_init; fi
  ensure_excludes
  log "Fertig: Haben $TARGET ist installiert."
}

APP_PID=""
KILLER_PID=""
STOPPING=0
on_signal() {
  STOPPING=1
  log "Beende Haben …"
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2> /dev/null; then
    kill -TERM "$APP_PID" 2> /dev/null || true
    # Notbremse, falls der Server nicht reagiert
    (sleep 30 && kill -KILL "$APP_PID" 2> /dev/null) &
    KILLER_PID=$!
  fi
}

ready_watch() {
  local probe_host="$HOST" _
  case "$probe_host" in "" | 0.0.0.0 | "::" | "[::]") probe_host="127.0.0.1" ;; esac
  case "$probe_host" in *:*) probe_host="[$probe_host]" ;; esac
  local url="http://$probe_host:$PORT/login"
  for _ in $(seq 1 600); do
    sleep 1
    kill -0 "$APP_PID" 2> /dev/null || return 0
    if bun -e "fetch('$url').then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))" > /dev/null 2>&1; then
      log "Haben ist bereit: $BETTER_AUTH_URL (intern http://$probe_host:$PORT)"
      return 0
    fi
  done
  log "WARNUNG: Haben antwortet nach 10 Minuten noch nicht auf $url"
}

# Lokaler Dump alle HABEN_DUMP_INTERVAL Minuten, damit jedes AMP-Backup einen frischen Stand enthält
dump_loop() {
  local minutes="${HABEN_DUMP_INTERVAL:-60}" sp=""
  [[ "$minutes" =~ ^[0-9]+$ ]] && [ "$minutes" -gt 0 ] || return 0
  trap 'kill "$sp" 2> /dev/null; exit 0' TERM
  while :; do
    sleep $((minutes * 60)) &
    sp=$!
    wait "$sp"
    HABEN_QUIET=1 bash "$SELF" dump || log "WARNUNG: lokaler Dump fehlgeschlagen"
  done
}

# restic-Sicherung täglich um HABEN_BACKUP_TIME (HH:MM)
backup_loop() {
  local at="${HABEN_BACKUP_TIME:-}" now next sp=""
  case "${HABEN_BACKUP_TARGET:-off}" in "" | off) return 0 ;; esac
  [ -n "$at" ] || at="03:15"
  if ! [[ "$at" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    log "WARNUNG: Uhrzeit der Sicherung '$at' ist nicht HH:MM; nehme 03:15."
    at="03:15"
  fi
  trap 'kill "$sp" 2> /dev/null; exit 0' TERM
  while :; do
    now="$(date +%s)"
    next="$(date -d "today $at" +%s)"
    [ "$next" -gt "$now" ] || next="$(date -d "tomorrow $at" +%s)"
    log "Nächste restic-Sicherung: $(date -d "@$next" '+%F %R')"
    sleep $((next - now)) &
    sp=$!
    wait "$sp"
    bash "$SELF" sicherung || log "WARNUNG: restic-Sicherung fehlgeschlagen, nächster Versuch zur gewohnten Zeit."
  done
}

console_help() {
  log "Befehle: dump (lokalen Dump für AMP-Backups erneuern), sicherung (restic-Sicherung jetzt),"
  log "         pruefung [id] (Test-Restore), snapshots (restic-Stände), hilfe"
}

# Befehle aus der AMP-Konsole (auch für AMP-Zeitpläne: erst „dump“ senden, dann Backup erstellen)
console_loop() {
  local line cmd arg
  while IFS= read -r line <&4; do
    line="${line//$'\r'/}"
    read -r cmd arg _ <<< "$line" || true
    case "${cmd,,}" in
      "") ;;
      dump) bash "$SELF" dump || log "Dump fehlgeschlagen" ;;
      sicherung | backup) bash "$SELF" sicherung || log "restic-Sicherung fehlgeschlagen" ;;
      pruefung | check) bash "$SELF" pruefung "${arg:-latest}" || true ;;
      snapshots) bash "$SELF" snapshots || true ;;
      hilfe | help | "?") console_help ;;
      *) log "Unbekannter Befehl '$cmd'. 'hilfe' zeigt alle Befehle." ;;
    esac
  done
}

cmd_run() {
  need flock gzip
  init_common
  [ -x "$BUN_DIR/bin/bun" ] && [ -f "$WEB/.output/server/index.mjs" ] \
    || die "Haben ist noch nicht installiert. Bitte in AMP zuerst 'Update' ausführen."
  [ -n "${BETTER_AUTH_URL:-}" ] || die "Öffentliche Adresse fehlt (Einstellungen › Haben › Öffentliche Adresse)."

  export NODE_ENV=production
  export HOST="${HOST:-0.0.0.0}" PORT="${PORT:-3000}"
  export DOCUMENTS_DIR="$DATA/belege" ERIC_DIR="$DATA/eric" ERIC_LOG_DIR="$LOGS/eric"
  export ERIC_WORKER_PATH="$APP/packages/elster/src/worker.ts" HABEN_EINVOICE_DIR="$APP/packages/einvoice"
  export TMPDIR="$ROOT/tmp"
  if [ -f "$DATA/enablebanking.pem" ]; then export ENABLE_BANKING_KEY_FILE="$DATA/enablebanking.pem"; fi

  trap on_signal TERM INT HUP

  if embedded; then
    pg_bin lenient
    restore_if_needed
    pg_bin
    pg_init
    pg_start
    pg_ensure_db
    export DATABASE_URL="postgres://haben:${HABEN_DB_PASSWORD}@127.0.0.1:${DB_PORT}/haben"
  else
    pg_bin
    [ -n "${HABEN_EXTERNAL_DATABASE_URL:-}" ] || die "Datenbank-Modus 'extern', aber keine Datenbank-URL eingetragen."
    export DATABASE_URL="$HABEN_EXTERNAL_DATABASE_URL"
  fi
  ensure_excludes
  load_user_env

  # Haben selbst bekommt weder Werkzeug-Variablen von PostgreSQL noch Zugangsdaten der Sicherung
  local app_env=(env) name
  for name in $(compgen -e); do
    case "$name" in
      PG* | RESTIC_* | AWS_* | HABEN_BACKUP_* | HABEN_DB_PASSWORD | HABEN_EXTERNAL_DATABASE_URL) app_env+=(-u "$name") ;;
    esac
  done

  cd "$WEB"
  if ! "${app_env[@]}" bun src/server/db/migrate.ts; then
    if embedded; then pg_stop; fi
    die "Migrationen fehlgeschlagen"
  fi
  if [ "$STOPPING" = 1 ]; then
    if embedded; then pg_stop; fi
    exit 0
  fi

  # Wie deploy/entrypoint.sh von Haben: ERiC beim Start laden, falls gewünscht und noch nicht vorhanden
  if [ -z "${ERIC_HOME:-}" ] && [ "${ERIC_AUTO_INSTALL:-}" = "ja" ]; then
    "${app_env[@]}" bun "$APP/packages/elster/src/install-cli.ts" --lizenz-akzeptiert --nur-wenn-fehlt \
      || log "ERiC konnte nicht geladen werden; Prüfen und Senden laufen simuliert."
  fi

  log "Starte Haben auf $HOST:$PORT (öffentlich: $BETTER_AUTH_URL)"
  "${app_env[@]}" bun .output/server/index.mjs &
  APP_PID=$!
  local helpers=()
  ready_watch &
  helpers+=("$!")
  dump_loop &
  helpers+=("$!")
  backup_loop &
  helpers+=("$!")
  exec 4<&0
  console_loop &
  helpers+=("$!")

  local rc=0
  while :; do
    set +e
    wait "$APP_PID"
    rc=$?
    set -e
    kill -0 "$APP_PID" 2> /dev/null || break
  done

  kill "${helpers[@]}" ${KILLER_PID:+"$KILLER_PID"} 2> /dev/null || true
  # Letzter Dump bei gestopptem Haben: AMP-Backups einer gestoppten Instanz sind damit exakt
  HABEN_QUIET=1 HABEN_LOCK_WAIT=240 bash "$SELF" dump || log "WARNUNG: Dump beim Beenden fehlgeschlagen"
  if embedded; then
    exec 9> "$RUN/sicherung.lock"
    flock -w 240 9 || log "WARNUNG: eine Sicherung läuft noch, PostgreSQL wird trotzdem beendet"
    log "Beende PostgreSQL …"
    pg_stop
  fi
  if [ "$STOPPING" = 1 ]; then
    log "Haben beendet."
    exit 0
  fi
  log "Haben wurde unerwartet beendet (Code $rc)."
  exit "$rc"
}

case "${1:-}" in
  install) cmd_install ;;
  run) cmd_run ;;
  dump) cmd_dump ;;
  sicherung | backup) cmd_sicherung ;;
  pruefung | check) cmd_pruefung "${2:-latest}" ;;
  snapshots) cmd_snapshots ;;
  *)
    echo "Aufruf: $0 install|run|dump|sicherung|pruefung [id]|snapshots" >&2
    exit 2
    ;;
esac

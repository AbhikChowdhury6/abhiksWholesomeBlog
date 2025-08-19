#!/usr/bin/env bash
set -euo pipefail

# Load environment variables from exenv.txt (primary) and .env (fallback)
set -a
[ -f .env ] && . ./.env
set +a

# Defaults from environment variables (override by exporting before running)
DB_VOL="${DB_VOL:-${DB_VOLUME:-db_data}}"
WP_VOL="${WP_VOL:-${WP_VOLUME:-wordpress_data}}"

# SSL/Domain configuration from environment
PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-}"
ALT_DOMAINS="${ALT_DOMAINS:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"

# Build domains array
DOMAINS=()
if [[ -n "$PRIMARY_DOMAIN" ]]; then
  DOMAINS+=("$PRIMARY_DOMAIN")
fi
if [[ -n "$ALT_DOMAINS" ]]; then
  read -r -a alt_domains_array <<< "$ALT_DOMAINS"
  DOMAINS+=("${alt_domains_array[@]}")
fi

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [BACKUP_DIR] [--wpfiles /path/to/wpfiles.tar(.gz)] [--db /path/to/{db.sql(.gz)|db_data.tar(.gz)}] [--yes|-y] [--ssl-check] [--force-ssl]

Examples:
  $(basename "$0") backup/20250818T063015Z
  $(basename "$0") --dir backup/20250818T063015Z
  $(basename "$0") --wpfiles backup/20250818T063015Z/wpfiles.tar.gz --db backup/20250818T063015Z/db.sql.gz
  $(basename "$0") backup/20250818T063015Z --ssl-check --force-ssl

Notes:
  If BACKUP_DIR (or --dir) is provided, the script auto-detects:
    - WordPress files: wpfiles*.tar(.gz)
    - Database: prefers db*.sql(.gz), falls back to db*_data*.tar(.gz)

  --db can be either:
    - SQL dump  (.sql or .sql.gz) -> imported into fresh MariaDB
    - Raw volume tar (.tar or .tar.gz) -> extracted directly into ${DB_VOL} (only safe if taken while DB was stopped)

  SSL Options:
    --ssl-check: Check SSL certificate validity and expiration
    --force-ssl: Force reissuing of SSL certificates even if they exist

Environment Variables (from exenv.txt):
  PRIMARY_DOMAIN=${PRIMARY_DOMAIN:-<not set>}
  ALT_DOMAINS=${ALT_DOMAINS:-<not set>}
  CERTBOT_EMAIL=${CERTBOT_EMAIL:-<not set>}
  DB_VOLUME=${DB_VOLUME:-<not set>}
  WP_VOLUME=${WP_VOLUME:-<not set>}

Env overrides:
  DB_VOL=${DB_VOL}   WP_VOL=${WP_VOL}
EOF
  exit 1
}

DB_FILE=""
WP_FILE=""
YES=0
BACKUP_DIR=""
SSL_CHECK=0
FORCE_SSL=0

# Backwards & new flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db=*) DB_FILE="${1#*=}";;
    --db) shift; DB_FILE="${1-}";;
    --wpfiles=*) WP_FILE="${1#*=}";;
    --wpfiles) shift; WP_FILE="${1-}";;
    --dir=*) BACKUP_DIR="${1#*=}";;
    --dir) shift; BACKUP_DIR="${1-}";;
    --yes|-y) YES=1;;
    --ssl-check) SSL_CHECK=1;;
    --force-ssl) FORCE_SSL=1;;
    -h|--help) usage;;
    -*)
      echo "Unknown arg: $1"; usage;;
    *)
      # first non-flag positional treated as BACKUP_DIR
      if [[ -z "$BACKUP_DIR" && -d "$1" ]]; then
        BACKUP_DIR="$1"
      else
        echo "Unknown arg or not a directory: $1"; usage
      fi
      ;;
  esac
  shift
done

# If a backup dir was provided, auto-detect files (unless explicitly set)
if [[ -n "${BACKUP_DIR}" ]]; then
  [[ -d "${BACKUP_DIR}" ]] || { echo "Backup dir not found: ${BACKUP_DIR}"; exit 1; }

  # Autodetect WP tar
  if [[ -z "${WP_FILE}" ]]; then
    for c in "wpfiles.tar.gz" "wpfiles-*.tar.gz" "wpfiles.tar" "wpfiles-*.tar"; do
      found=( "${BACKUP_DIR}"/$c )
      [[ -e "${found[0]}" ]] && { WP_FILE="${found[0]}"; break; }
    done
  fi

  # Autodetect DB file: prefer SQL, then raw tar
  if [[ -z "${DB_FILE}" ]]; then
    # prefer SQL
    for c in "db.sql.gz" "db.sql" "db-*.sql.gz" "db-*.sql" "*.sql.gz" "*.sql"; do
      found=( "${BACKUP_DIR}"/$c )
      [[ -e "${found[0]}" ]] && { DB_FILE="${found[0]}"; break; }
    done
    # fallback to tar if still empty
    if [[ -z "${DB_FILE}" ]]; then
      for c in "db_data.tar.gz" "db_data-*.tar.gz" "db_data.tar" "db_data-*.tar" "db*.tar.gz" "db*.tar"; do
        found=( "${BACKUP_DIR}"/$c )
        [[ -e "${found[0]}" ]] && { DB_FILE="${found[0]}"; break; }
      done
    fi
  fi
fi

[[ -n "${DB_FILE}" && -n "${WP_FILE}" ]] || usage
[[ -f "${DB_FILE}" ]] || { echo "DB file not found: ${DB_FILE}"; exit 1; }
[[ -f "${WP_FILE}" ]] || { echo "WP files tar not found: ${WP_FILE}"; exit 1; }

# Decide DB restore mode
DB_MODE=""
case "${DB_FILE}" in
  *.sql|*.sql.gz) DB_MODE="sql" ;;
  *.tar|*.tar.gz) DB_MODE="volume" ;;
  *) echo "Cannot infer DB file type. Use .sql/.sql.gz for SQL or .tar(.gz) for raw volume."; exit 1 ;;
esac

# Pick compose command
if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo "Neither 'docker compose' nor 'docker-compose' found." >&2
  exit 1
fi

echo "==> Plan:"
echo "   - Restore WordPress files tar -> volume '${WP_VOL}'"
echo "   - Restore DB (${DB_MODE}) -> volume '${DB_VOL}'"
echo "   - WP files: ${WP_FILE}"
echo "   - DB file : ${DB_FILE}"
if [[ $SSL_CHECK -eq 1 ]]; then
  echo "   - SSL certificate check and reissuing enabled"
  if [[ $FORCE_SSL -eq 1 ]]; then
    echo "   - Force SSL certificate reissuing"
  fi
fi
if [[ $YES -ne 1 ]]; then
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

untar_into_volume() {
  local vol="$1"
  local file="$2"
  local dir; dir="$(cd "$(dirname "$file")" && pwd)"
  local base; base="$(basename "$file")"
  local flags="xf"
  [[ "$base" =~ \.tar\.gz$ || "$base" =~ \.tgz$ ]] && flags="xzf"
  docker run --rm -v "${vol}":/volume -v "${dir}":/backup alpine \
    sh -lc 'set -e; rm -rf /volume/*; tar '"$flags"' "/backup/'"$base"'" -C /volume'
}

wait_for_db() {
  echo -n "==> Waiting for DB to accept connections"
  until "${DC[@]}" exec -T db sh -lc '
    set -e
    ping_cmd=""
    if command -v mariadb-admin >/dev/null 2>&1; then
      ping_cmd="mariadb-admin"
    elif command -v mysqladmin >/dev/null 2>&1; then
      ping_cmd="mysqladmin"
    fi
    [ -n "$ping_cmd" ] && (
      "$ping_cmd" ping -h 127.0.0.1 -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --silent ||
      "$ping_cmd" ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent
    )
  '; do
    printf '.'
    sleep 2
  done
  echo
}

# SSL Certificate functions
check_ssl_certificate() {
  local domain="$1"
  local cert_file="./letsencrypt/live/$domain/fullchain.pem"
  
  if [[ ! -f "$cert_file" ]]; then
    echo "    Certificate not found for $domain"
    return 1
  fi
  
  # Check certificate expiration
  local expiry_date
  expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
  if [[ $? -ne 0 ]]; then
    echo "    Error reading certificate for $domain"
    return 1
  fi
  
  # Convert to timestamp and check if expired or expiring soon (30 days)
  local expiry_timestamp
  expiry_timestamp=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
  local current_timestamp
  current_timestamp=$(date +%s)
  local days_until_expiry
  days_until_expiry=$(( (expiry_timestamp - current_timestamp) / 86400 ))
  
  if [[ $days_until_expiry -le 0 ]]; then
    echo "    Certificate for $domain is EXPIRED"
    return 1
  elif [[ $days_until_expiry -le 30 ]]; then
    echo "    Certificate for $domain expires in $days_until_expiry days"
    return 1
  else
    echo "    Certificate for $domain is valid for $days_until_expiry days"
    return 0
  fi
}

ensure_nginx_dirs() { 
  mkdir -p nginx/conf.d nginx/certbot letsencrypt
}

render_nginx_conf() {
  local out="nginx/conf.d/wp.conf"
  
  # Check if we have domain configuration
  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    echo "==> No domains configured, skipping nginx config generation"
    return 0
  fi
  
  local primary_domain="${DOMAINS[0]}"
  local server_names=""
  
  # Build server names string
  for domain in "${DOMAINS[@]}"; do
    server_names="${server_names} ${domain}"
  done
  server_names="${server_names# }"  # Remove leading space
  
  echo "==> Generating nginx config for domains: ${server_names}"
  
  # Create nginx configuration
  cat > "$out" <<EOF
# HTTP: serve ACME challenges and redirect everything else to HTTPS
server {
  listen 80;
  server_name ${server_names};

  # ACME (must be reachable on port 80 for renewals)
  location /.well-known/acme-challenge/ {
    root /var/www/certbot;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

# HTTPS: terminate TLS and proxy to WordPress
server {
  listen 443 ssl http2;
  server_name ${server_names};

  ssl_certificate     /etc/letsencrypt/live/${primary_domain}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${primary_domain}/privkey.pem;

  # (Optional) Basic TLS hardening — safe defaults
  ssl_session_timeout 1d;
  ssl_session_cache shared:MozSSL:10m;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;

  # Serve ACME path here too (harmless, helps if someone hits https://)
  location /.well-known/acme-challenge/ {
    root /var/www/certbot;
  }

  # Allow larger media/uploads in WP
  client_max_body_size 64m;

  location / {
    proxy_pass http://wordpress:80;  # service name in your compose network
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
}

start_nginx() {
  echo "==> Starting/ensuring Nginx is up"
  ensure_nginx_dirs
  render_nginx_conf
  "${DC[@]}" up -d nginx
  "${DC[@]}" exec nginx nginx -t >/dev/null
}

test_acme_path() {
  local host="$1"
  echo "==> Verifying ACME webroot can be served for Host: $host"
  mkdir -p nginx/certbot/.well-known/acme-challenge
  echo "ok" > nginx/certbot/.well-known/acme-challenge/ping
  "${DC[@]}" exec nginx nginx -s reload
  curl -fsS -H "Host: $host" "http://127.0.0.1/.well-known/acme-challenge/ping" >/dev/null \
    && echo "    ACME path OK" \
    || { echo "    ERROR: ACME path not reachable. Check nginx/conf.d/wp.conf and mounts."; exit 1; }
}

issue_certs_webroot() {
  # Check if we have required configuration
  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    echo "==> No domains configured, skipping certificate issuance"
    return 0
  fi
  
  if [[ -z "$CERTBOT_EMAIL" ]]; then
    echo "==> No cert email provided (CERTBOT_EMAIL in exenv.txt), skipping certificate issuance"
    return 0
  fi

  local primary="${DOMAINS[0]}"
  local live_dir="./letsencrypt/live/$primary"

  # Check if certificate exists and is valid (unless force is enabled)
  if [[ -f "$live_dir/fullchain.pem" && $FORCE_SSL -ne 1 ]]; then
    if check_ssl_certificate "$primary"; then
      echo "==> Valid certificate already exists for $primary; skipping (use --force-ssl to re-issue)."
      return 0
    else
      echo "==> Certificate for $primary is invalid or expiring soon, will re-issue"
    fi
  fi

  echo "==> Running Certbot (webroot) for: ${DOMAINS[*]}"
  local args=( certonly --webroot -w /var/www/certbot --email "$CERTBOT_EMAIL" --agree-tos --no-eff-email )
  for d in "${DOMAINS[@]}"; do args+=( -d "$d" ); done

  docker run --rm \
    -v "$PWD/letsencrypt:/etc/letsencrypt" \
    -v "$PWD/nginx/certbot:/var/www/certbot" \
    certbot/certbot "${args[@]}"

  [[ -f "$live_dir/fullchain.pem" ]] || { echo "ERROR: cert issuance appears to have failed."; exit 1; }
  echo "==> Reloading Nginx"
  "${DC[@]}" exec nginx nginx -s reload
}

# Bring stack down to avoid writes during restore
"${DC[@]}" down

# Ensure volumes exist
docker volume inspect "${WP_VOL}" >/dev/null 2>&1 || docker volume create "${WP_VOL}" >/dev/null
docker volume inspect "${DB_VOL}" >/dev/null 2>&1 || docker volume create "${DB_VOL}" >/dev/null

echo "==> Restoring WordPress files to volume '${WP_VOL}'"
untar_into_volume "${WP_VOL}" "${WP_FILE}"

if [[ "${DB_MODE}" == "volume" ]]; then
  echo "==> Restoring DB volume '${DB_VOL}' from raw tar (assumed cold/clean backup)"
  untar_into_volume "${DB_VOL}" "${DB_FILE}"

  echo "==> Starting DB + WordPress"
  "${DC[@]}" up -d db
  wait_for_db
  "${DC[@]}" up -d wordpress

else
  echo "==> Starting DB container to import SQL"
  "${DC[@]}" up -d db
  wait_for_db

  echo "==> Importing SQL into database '${MYSQL_DATABASE}'"
  if [[ "${DB_FILE}" == *.gz ]]; then
    gunzip -c "${DB_FILE}" | "${DC[@]}" exec -T db sh -lc '
      set -e
      client="mariadb"
      command -v mariadb >/dev/null 2>&1 || client="mysql"
      "$client" -h 127.0.0.1 -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"
    '
  else
    cat "${DB_FILE}" | "${DC[@]}" exec -T db sh -lc '
      set -e
      client="mariadb"
      command -v mariadb >/dev/null 2>&1 || client="mysql"
      "$client" -h 127.0.0.1 -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"
    '
  fi

  echo "==> Starting WordPress"
  "${DC[@]}" up -d wordpress
fi

# SSL Certificate handling
if [[ $SSL_CHECK -eq 1 ]]; then
  echo "==> Checking SSL certificates"
  
  # Start nginx if not already running
  if ! "${DC[@]}" ps nginx >/dev/null 2>&1; then
    start_nginx
  fi
  
  # Check certificates for all domains
  local cert_issues=0
  for domain in "${DOMAINS[@]}"; do
    if ! check_ssl_certificate "$domain"; then
      cert_issues=1
    fi
  done
  
  # Re-issue certificates if needed
  if [[ $cert_issues -eq 1 || $FORCE_SSL -eq 1 ]]; then
    echo "==> Certificate issues detected, re-issuing certificates"
    # Test ACME path for primary domain
    local primary="${DOMAINS[0]}"
    [[ -n "$primary" ]] && test_acme_path "$primary"
    issue_certs_webroot
  else
    echo "==> All certificates are valid"
  fi
fi

echo "==> Restore complete."
"${DC[@]}" ps

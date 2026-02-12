#!/bin/bash
#
# setup_multi.sh — Start/stop a single Poste.io instance by index number.
# Each instance gets unique ports derived from its index:
#   Web:        BASE_WEB        + index  (default 10005 + index)
#   SMTP:       BASE_SMTP       + index  (default 2525  + index)
#   IMAP:       BASE_IMAP       + index  (default 1143  + index)
#   Submission: BASE_SUBMISSION + index  (default 1587  + index)
#
# Usage:
#   bash setup_multi.sh start <index>          # start instance N (full setup)
#   bash setup_multi.sh stop <index>           # stop instance N
#   bash setup_multi.sh build_golden           # build golden image with all users
#   bash setup_multi.sh start_all <count>      # clone golden image to N instances
#   bash setup_multi.sh stop_all <count>       # stop instances 0..(count-1)
#   bash setup_multi.sh status                 # show all running poste instances
#   bash setup_multi.sh config <index>         # configure dovecot for instance N
#
# Environment variables (override defaults):
#   BASE_WEB          — base web port         (default: 10005)
#   BASE_SMTP         — base SMTP port        (default: 2525)
#   BASE_IMAP         — base IMAP port        (default: 1143)
#   BASE_SUBMISSION   — base submission port   (default: 1587)
#   NUM_USERS         — users to create per instance (default: 503)
#   MAX_PARALLEL      — max parallel instance starts (default: 10)
#   CONFIGURE_DOVECOT — whether to configure dovecot (default: true)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ── Base ports (instance 0 gets these exact ports) ───────────────────
BASE_WEB=${BASE_WEB:-10005}
BASE_SMTP=${BASE_SMTP:-2525}
BASE_IMAP=${BASE_IMAP:-1143}
BASE_SUBMISSION=${BASE_SUBMISSION:-1587}
NUM_USERS=${NUM_USERS:-503}
MAX_PARALLEL=${MAX_PARALLEL:-10}
CONFIGURE_DOVECOT=${CONFIGURE_DOVECOT:-true}
DOMAIN="mcp.com"
DOCKER="docker"
GOLDEN_IMAGE="poste-golden:latest"
BASE_IMAGE="analogic/poste.io:2.5.5"

# ── Derived values for a given index ────────────────────────────────
get_ports() {
  local idx=$1
  WEB_PORT=$((BASE_WEB + idx))
  SMTP_PORT=$((BASE_SMTP + idx))
  IMAP_PORT=$((BASE_IMAP + idx))
  SUBMISSION_PORT=$((BASE_SUBMISSION + idx))
}

get_container_name() {
  echo "poste-${1}"
}

get_data_dir() {
  echo "$PROJECT_ROOT/deployment/poste/data/instance-${1}"
}

# ── Start a single instance ─────────────────────────────────────────
# $1 = index, $2 = image (optional, default BASE_IMAGE)
start_instance() {
  local idx=$1
  local image=${2:-$BASE_IMAGE}
  local container_name=$(get_container_name "$idx")
  local data_dir=$(get_data_dir "$idx")
  get_ports "$idx"

  # Skip if already running
  if $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container_name"; then
    echo "⏭️  Instance $idx ($container_name) already running, skipping"
    return 0
  fi

  # Clean up stopped container with same name
  $DOCKER rm -f "$container_name" 2>/dev/null || true

  # Prepare data dir
  mkdir -p "$data_dir"
  chmod -R 777 "$data_dir"

  echo "🚀 Starting instance $idx: web=$WEB_PORT smtp=$SMTP_PORT imap=$IMAP_PORT submission=$SUBMISSION_PORT image=$image"

  $DOCKER run -d \
    --name "$container_name" \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --cap-add NET_BIND_SERVICE \
    --cap-add SYS_PTRACE \
    -p "${WEB_PORT}:80" \
    -p "${SMTP_PORT}:25" \
    -p "${IMAP_PORT}:143" \
    -p "${SUBMISSION_PORT}:587" \
    -e "DISABLE_CLAMAV=TRUE" \
    -e "DISABLE_RSPAMD=TRUE" \
    -e "DISABLE_P0F=TRUE" \
    -e "HTTPS_FORCE=0" \
    -e "HTTPS=OFF" \
    -v "${data_dir}:/data:Z" \
    --hostname "$DOMAIN" \
    "$image"

  if [ $? -eq 0 ]; then
    echo "✅ Instance $idx started"
  else
    echo "❌ Instance $idx failed to start"
    return 1
  fi
}

# ── Stop a single instance ──────────────────────────────────────────
stop_instance() {
  local idx=$1
  local container_name=$(get_container_name "$idx")
  local data_dir=$(get_data_dir "$idx")

  echo "🛑 Stopping instance $idx ($container_name)..."
  $DOCKER stop "$container_name" 2>/dev/null || true
  $DOCKER rm -f "$container_name" 2>/dev/null || true

  # Clean data dir
  if [ -d "$data_dir" ]; then
    rm -rf "$data_dir" 2>/dev/null || sudo rm -rf "$data_dir" 2>/dev/null || true
  fi

  echo "✅ Instance $idx stopped"
}

# ── Configure dovecot for a single instance ─────────────────────────
configure_instance() {
  local idx=$1
  local container_name=$(get_container_name "$idx")

  # Check container is running
  if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container_name"; then
    echo "⚠️  Instance $idx not running, skipping config"
    return 1
  fi

  # Dovecot SSL
  $DOCKER exec "$container_name" sed -i 's/ssl = required/ssl = yes/' /etc/dovecot/conf.d/10-ssl.conf 2>/dev/null || true
  # Dovecot cleartext auth
  $DOCKER exec "$container_name" sed -i 's/auth_allow_cleartext = no/auth_allow_cleartext = yes/' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true
  $DOCKER exec "$container_name" sed -i '/disable_plaintext_auth/d' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true
  # Haraka SMTP
  $DOCKER exec "$container_name" sed -i 's/tls_required = true/tls_required = false/' /opt/haraka-smtp/config/auth.ini 2>/dev/null || true
  # Haraka Submission
  $DOCKER exec "$container_name" sed -i 's/tls_required = true/tls_required = false/' /opt/haraka-submission/config/auth.ini 2>/dev/null || true
  # Disable auth plugin for submission
  $DOCKER exec "$container_name" sed -i 's/^auth\/poste/#auth\/poste/' /opt/haraka-submission/config/plugins 2>/dev/null || true
  # Relay ACL
  $DOCKER exec "$container_name" sh -c 'echo "127.0.0.1/8" > /opt/haraka-submission/config/relay_acl_allow' 2>/dev/null || true
  $DOCKER exec "$container_name" sh -c 'echo "192.168.0.0/16" >> /opt/haraka-submission/config/relay_acl_allow' 2>/dev/null || true
  $DOCKER exec "$container_name" sh -c 'echo "172.16.0.0/12" >> /opt/haraka-submission/config/relay_acl_allow' 2>/dev/null || true
  $DOCKER exec "$container_name" sh -c 'echo "10.0.0.0/8" >> /opt/haraka-submission/config/relay_acl_allow' 2>/dev/null || true

  # Reload services
  $DOCKER exec "$container_name" doveadm reload 2>/dev/null || true
  $DOCKER exec "$container_name" sh -c 'kill $(pgrep -f "haraka.*smtp")' 2>/dev/null || true
  $DOCKER exec "$container_name" sh -c 'kill $(pgrep -f "haraka.*submission")' 2>/dev/null || true

  echo "✅ Instance $idx configured"
}

# ── Create users for a single instance ──────────────────────────────
create_users_instance() {
  local idx=$1
  local container_name=$(get_container_name "$idx")

  if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container_name"; then
    echo "⚠️  Instance $idx not running, skipping user creation"
    return 1
  fi

  # Ensure domain exists
  if ! $DOCKER exec --user=8 "$container_name" php /opt/admin/bin/console domain:list 2>/dev/null | grep -q "$DOMAIN"; then
    $DOCKER exec --user=8 "$container_name" php /opt/admin/bin/console domain:create "$DOMAIN" 2>/dev/null || true
  fi

  # Create admin
  $DOCKER exec --user=8 "$container_name" php /opt/admin/bin/console email:create "mcpposte_admin@$DOMAIN" "mcpposte" "System Administrator" 2>/dev/null || true
  $DOCKER exec --user=8 "$container_name" php /opt/admin/bin/console email:admin "mcpposte_admin@$DOMAIN" 2>/dev/null || true

  # Create users from JSON in parallel batches using jq + bash (no python needed)
  local users_json="$PROJECT_ROOT/configs/users_data.json"
  if [ ! -f "$users_json" ]; then
    echo "⚠️  users_data.json not found, skipping user creation for instance $idx"
    return 1
  fi

  echo "👥 Creating users for instance $idx..."
  local counter=0
  while IFS='|' read -r email password full_name; do
    counter=$((counter + 1))
    [ $counter -gt $NUM_USERS ] && break
    $DOCKER exec --user=8 "$container_name" php /opt/admin/bin/console email:create "$email" "$password" "$full_name" 2>/dev/null &
    # Wait every 50 to avoid overwhelming the container
    [ $((counter % 50)) -eq 0 ] && wait
  done < <(jq -r ".users[] | \"\(.email)|\(.password)|\(.full_name)\"" "$users_json")
  wait

  echo "✅ Users created for instance $idx ($counter users)"
}

# ── Wait for web server and initialize database ────────────────────
wait_for_ready() {
  local idx=$1
  local container_name=$(get_container_name "$idx")
  local max_attempts=90   # up to 180 seconds
  local attempt=0

  # Phase 1: Wait for internal web server to come up
  echo "⏳ [${idx}] Waiting for web server..."
  while [ $attempt -lt $max_attempts ]; do
    local http_code
    http_code=$($DOCKER exec "$container_name" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:80/ 2>/dev/null || echo "000")
    # Trim whitespace and take only last 3 chars (curl may prefix extra output)
    http_code=$(echo "$http_code" | tr -d '[:space:]' | tail -c 3)
    # Match any valid HTTP response code (1xx-5xx); reject "000" or other non-HTTP outputs
    if [[ ${#http_code} -eq 3 ]] && [[ "$http_code" =~ ^[1-5][0-9][0-9]$ ]]; then
      echo "  ✓ [${idx}] Web server up (HTTP $http_code, ~$((attempt * 2))s)"
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  if [ $attempt -ge $max_attempts ]; then
    echo "⚠️  [${idx}] Web server not responding after 180s"
    return 1
  fi

  # Phase 2: Check if DB is already initialized (has domains table)
  local output
  output=$($DOCKER exec --user=8 "$container_name" php /opt/admin/bin/console domain:list 2>&1)
  if ! echo "$output" | grep -q "no such table"; then
    echo "✅ [${idx}] Database already initialized"
    return 0
  fi

  # Phase 3: Delete partial DB and create schema from scratch
  # Poste.io creates a partial DB on startup (webauthn, guard, etc.) but
  # misses critical tables (domains, emails). Deleting and recreating fixes this.
  echo "  → [${idx}] Initializing database schema..."
  $DOCKER exec "$container_name" rm -f /data/users.db 2>/dev/null || true
  $DOCKER exec --user=8 "$container_name" php /opt/admin/bin/console doctrine:schema:create --no-interaction 2>/dev/null || true
  sleep 2

  # Verify schema was created
  output=$($DOCKER exec --user=8 "$container_name" php /opt/admin/bin/console domain:list 2>&1)
  if echo "$output" | grep -q "no such table"; then
    echo "⚠️  [${idx}] doctrine:schema:create failed, retrying..."
    $DOCKER exec "$container_name" rm -f /data/users.db 2>/dev/null || true
    sleep 3
    $DOCKER exec --user=8 "$container_name" php /opt/admin/bin/console doctrine:schema:create --no-interaction 2>/dev/null || true
    sleep 2
    output=$($DOCKER exec --user=8 "$container_name" php /opt/admin/bin/console domain:list 2>&1)
    if echo "$output" | grep -q "no such table"; then
      echo "⚠️  [${idx}] DB schema could not be created. Output: $output"
      return 1
    fi
  fi

  echo "✅ [${idx}] Database schema created"
  return 0
}

# ── Full setup for a single instance (start + configure + users) ────
full_setup_instance() {
  local idx=$1
  start_instance "$idx"
  if ! wait_for_ready "$idx"; then
    echo "❌ Instance $idx: wait_for_ready failed, skipping configure + user creation"
    return 1
  fi
  if [ "$CONFIGURE_DOVECOT" = "true" ]; then
    configure_instance "$idx"
  fi
  sleep 2
  if ! create_users_instance "$idx"; then
    echo "❌ Instance $idx: user creation failed"
    return 1
  fi
  echo "🎉 Instance $idx fully ready!"
}

# ── Build golden image: setup once, commit, reuse everywhere ────────
# IMPORTANT: The seed container runs WITHOUT a volume mount so that all
# data lives in the container's writable layer. docker commit only captures
# the container layer, not bind-mounted volumes.
build_golden() {
  echo "🏗️  Building golden image ($GOLDEN_IMAGE)..."
  echo "   This sets up 1 instance with all users, then commits it as a reusable image."
  echo ""

  local seed_name="poste-golden-seed"
  local seed_web=$((BASE_WEB + 9999))  # Use a high port to avoid conflicts

  # Clean up any previous seed
  $DOCKER rm -f "$seed_name" 2>/dev/null || true

  echo "🚀 Starting seed container (no volume mount — data stays in container layer)..."
  $DOCKER run -d \
    --name "$seed_name" \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --cap-add NET_BIND_SERVICE \
    --cap-add SYS_PTRACE \
    -p "${seed_web}:80" \
    -e "DISABLE_CLAMAV=TRUE" \
    -e "DISABLE_RSPAMD=TRUE" \
    -e "DISABLE_P0F=TRUE" \
    -e "HTTPS_FORCE=0" \
    -e "HTTPS=OFF" \
    --hostname "$DOMAIN" \
    "$BASE_IMAGE"

  # Wait for web server + DB to be ready
  echo "⏳ Waiting for seed container to be ready..."
  local max_attempts=90
  local attempt=0
  while [ $attempt -lt $max_attempts ]; do
    local http_code
    http_code=$($DOCKER exec "$seed_name" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:80/ 2>/dev/null || echo "000")
    http_code=$(echo "$http_code" | tr -d '[:space:]' | tail -c 3)
    if [[ ${#http_code} -eq 3 ]] && [[ "$http_code" =~ ^[1-5][0-9][0-9]$ ]]; then
      echo "  ✓ Web server up (HTTP $http_code, ~$((attempt * 2))s)"
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  if [ $attempt -ge $max_attempts ]; then
    echo "❌ Seed container web server not responding"
    $DOCKER rm -f "$seed_name" 2>/dev/null || true
    return 1
  fi

  # Initialize DB if needed
  local output
  output=$($DOCKER exec --user=8 "$seed_name" php /opt/admin/bin/console domain:list 2>&1)
  if echo "$output" | grep -q "no such table"; then
    echo "  → Initializing database schema..."
    $DOCKER exec "$seed_name" rm -f /data/users.db 2>/dev/null || true
    $DOCKER exec --user=8 "$seed_name" php /opt/admin/bin/console doctrine:schema:create --no-interaction 2>/dev/null || true
    sleep 2
  fi

  # Configure dovecot/haraka
  echo "🔧 Configuring services..."
  $DOCKER exec "$seed_name" sed -i 's/ssl = required/ssl = yes/' /etc/dovecot/conf.d/10-ssl.conf 2>/dev/null || true
  $DOCKER exec "$seed_name" sed -i 's/auth_allow_cleartext = no/auth_allow_cleartext = yes/' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true
  $DOCKER exec "$seed_name" sed -i '/disable_plaintext_auth/d' /etc/dovecot/conf.d/10-auth.conf 2>/dev/null || true
  $DOCKER exec "$seed_name" sed -i 's/tls_required = true/tls_required = false/' /opt/haraka-smtp/config/auth.ini 2>/dev/null || true
  $DOCKER exec "$seed_name" sed -i 's/tls_required = true/tls_required = false/' /opt/haraka-submission/config/auth.ini 2>/dev/null || true
  $DOCKER exec "$seed_name" sed -i 's/^auth\/poste/#auth\/poste/' /opt/haraka-submission/config/plugins 2>/dev/null || true
  $DOCKER exec "$seed_name" sh -c 'echo "127.0.0.1/8" > /opt/haraka-submission/config/relay_acl_allow' 2>/dev/null || true
  $DOCKER exec "$seed_name" sh -c 'echo "192.168.0.0/16" >> /opt/haraka-submission/config/relay_acl_allow' 2>/dev/null || true
  $DOCKER exec "$seed_name" sh -c 'echo "172.16.0.0/12" >> /opt/haraka-submission/config/relay_acl_allow' 2>/dev/null || true
  $DOCKER exec "$seed_name" sh -c 'echo "10.0.0.0/8" >> /opt/haraka-submission/config/relay_acl_allow' 2>/dev/null || true
  $DOCKER exec "$seed_name" doveadm reload 2>/dev/null || true

  # Create domain + users
  echo "👥 Creating domain and users..."
  if ! $DOCKER exec --user=8 "$seed_name" php /opt/admin/bin/console domain:list 2>/dev/null | grep -q "$DOMAIN"; then
    $DOCKER exec --user=8 "$seed_name" php /opt/admin/bin/console domain:create "$DOMAIN" 2>/dev/null || true
  fi
  $DOCKER exec --user=8 "$seed_name" php /opt/admin/bin/console email:create "mcpposte_admin@$DOMAIN" "mcpposte" "System Administrator" 2>/dev/null || true
  $DOCKER exec --user=8 "$seed_name" php /opt/admin/bin/console email:admin "mcpposte_admin@$DOMAIN" 2>/dev/null || true

  local users_json="$PROJECT_ROOT/configs/users_data.json"
  if [ -f "$users_json" ]; then
    local counter=0
    while IFS='|' read -r email password full_name; do
      counter=$((counter + 1))
      [ $counter -gt $NUM_USERS ] && break
      $DOCKER exec --user=8 "$seed_name" php /opt/admin/bin/console email:create "$email" "$password" "$full_name" 2>/dev/null &
      [ $((counter % 50)) -eq 0 ] && wait
    done < <(jq -r ".users[] | \"\(.email)|\(.password)|\(.full_name)\"" "$users_json")
    wait
    echo "✅ Created $counter users"
  fi

  echo ""
  echo "📦 Committing container to image: $GOLDEN_IMAGE"

  # IMPORTANT: The base image declares VOLUME /data, so docker commit skips /data.
  # We copy /data to /data_golden (not a volume) so it gets captured in the image.
  echo "  → Copying /data to /data_golden (workaround for VOLUME exclusion)..."
  $DOCKER exec "$seed_name" cp -a /data /data_golden

  # Stop the container cleanly before committing (ensures consistent state)
  $DOCKER stop "$seed_name"

  # Commit the container (with all data baked in) as a new image
  $DOCKER commit \
    --change 'CMD ["/init"]' \
    "$seed_name" \
    "$GOLDEN_IMAGE"

  if [ $? -eq 0 ]; then
    local image_size
    image_size=$($DOCKER image inspect "$GOLDEN_IMAGE" --format '{{.Size}}' 2>/dev/null | awk '{printf "%.0f MB", $1/1024/1024}')
    echo "✅ Golden image built: $GOLDEN_IMAGE ($image_size)"
  else
    echo "❌ Failed to commit golden image"
    return 1
  fi

  # Clean up the seed container
  $DOCKER rm -f "$seed_name" 2>/dev/null || true

  echo ""
  echo "🚀 Golden image ready! Now run:"
  echo "   $0 start_all <count>    # Clones golden image to N instances (fast, no user creation)"
}

# ── Start a single instance from golden image (fast, no setup) ──────
# Copies baked-in /data to a host dir first so data persists across restarts.
start_instance_from_golden() {
  local idx=$1
  local container_name=$(get_container_name "$idx")
  local data_dir=$(get_data_dir "$idx")
  get_ports "$idx"

  # Seed host data dir from the golden image (only if empty/missing)
  if [ ! -f "$data_dir/users.db" ]; then
    echo "📂 [${idx}] Seeding data dir from golden image..."
    mkdir -p "$data_dir"
    # Use docker run with bind-mount to reliably copy all files from /data_golden.
    # (docker create + docker cp silently skips files in committed layers)
    $DOCKER run --rm \
      -v "$data_dir":/export \
      --entrypoint sh \
      "$GOLDEN_IMAGE" \
      -c 'cp -a /data_golden/* /export/ 2>/dev/null; cp -a /data_golden/.??* /export/ 2>/dev/null; true'

    # Fix symlinks that point back to /data/... (they cause loops when host-mounted)
    for link in "$data_dir"/*; do
      if [ -L "$link" ]; then
        local target=$(readlink "$link")
        if [[ "$target" == /data/* ]]; then
          echo "  → [${idx}] Fixing symlink loop: $(basename "$link") -> $target"
          rm -f "$link"
          mkdir -p "$link"
        fi
      fi
    done

    chmod -R 777 "$data_dir"
    echo "  ✓ [${idx}] Seeded $(ls "$data_dir" | wc -l) items, users.db=$(du -h "$data_dir/users.db" 2>/dev/null | cut -f1)"
  fi

  # Start with host volume mount (data persists across crashes/restarts)
  start_instance "$idx" "$GOLDEN_IMAGE"

  echo "🎉 Instance $idx ready (cloned from golden image, data persistent)"
}

# ── Start all instances in parallel batches ─────────────────────────
start_all() {
  local count=${1:-5}

  # Check if golden image exists — if so, use fast clone path
  if $DOCKER image inspect "$GOLDEN_IMAGE" &>/dev/null; then
    echo "🚀 Starting $count instances from golden image (parallel=$MAX_PARALLEL)..."
    echo "   ⚡ Using pre-built image — no user creation needed!"
    echo ""

    local started=0
    local batch=0

    for ((i=0; i<count; i++)); do
      start_instance_from_golden "$i" &
      started=$((started + 1))

      if [ $((started % MAX_PARALLEL)) -eq 0 ]; then
        batch=$((batch + 1))
        echo "⏳ Waiting for batch $batch to complete..."
        wait
        echo "✅ Batch $batch done ($started/$count instances started)"
      fi
    done

    wait
  else
    echo "⚠️  Golden image not found ($GOLDEN_IMAGE)."
    echo "   Falling back to full setup per instance (slow)."
    echo "   💡 Tip: Run '$0 build_golden' first to create the golden image."
    echo ""
    echo "🚀 Starting $count Poste.io instances (parallel=$MAX_PARALLEL)..."
    echo ""

    local started=0
    local batch=0

    for ((i=0; i<count; i++)); do
      full_setup_instance "$i" &
      started=$((started + 1))

      if [ $((started % MAX_PARALLEL)) -eq 0 ]; then
        batch=$((batch + 1))
        echo "⏳ Waiting for batch $batch to complete..."
        wait
        echo "✅ Batch $batch done ($started/$count instances started)"
      fi
    done

    wait
  fi

  echo ""
  echo "🎉 All $count instances started!"
  echo ""
  show_status
}

# ── Stop all instances ──────────────────────────────────────────────
stop_all() {
  local count=${1:-200}
  echo "🛑 Stopping up to $count instances..."

  # Find all running poste-* containers
  local running
  running=$($DOCKER ps --format '{{.Names}}' 2>/dev/null | grep '^poste-[0-9]' || true)

  if [ -z "$running" ]; then
    echo "No running poste instances found."
    return 0
  fi

  while read -r name; do
    local idx=${name#poste-}
    stop_instance "$idx" &
  done <<< "$running"
  wait

  echo "✅ All instances stopped"
}

# ── Show status ─────────────────────────────────────────────────────
show_status() {
  echo "📊 Running Poste.io instances:"
  echo "─────────────────────────────────────────────────────────────────────"
  printf "%-12s %-8s %-8s %-8s %-12s %-10s\n" "CONTAINER" "WEB" "SMTP" "IMAP" "SUBMISSION" "STATUS"
  echo "─────────────────────────────────────────────────────────────────────"

  local running
  running=$($DOCKER ps --format '{{.Names}}' 2>/dev/null | grep '^poste-[0-9]' | sort -t'-' -k2 -n || true)

  if [ -z "$running" ]; then
    echo "(none)"
  else
    local total=0
    echo "$running" | while read -r name; do
      local idx=${name#poste-}
      get_ports "$idx"
      local status=$($DOCKER inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
      printf "%-12s %-8s %-8s %-8s %-12s %-10s\n" "$name" "$WEB_PORT" "$SMTP_PORT" "$IMAP_PORT" "$SUBMISSION_PORT" "$status"
    done
    echo "─────────────────────────────────────────────────────────────────────"
    echo "Total: $(echo "$running" | wc -l) instances"
  fi
}

# ── Generate email configs for all running instances ────────────────
generate_configs() {
  local output_dir="$PROJECT_ROOT/deployment/poste/configs/instances"
  mkdir -p "$output_dir"

  local running
  running=$($DOCKER ps --format '{{.Names}}' 2>/dev/null | grep '^poste-[0-9]' | sort -t'-' -k2 -n || true)

  if [ -z "$running" ]; then
    echo "No running instances. Start some first."
    return 1
  fi

  # Get the host IP (for remote access; localhost for local)
  local host_ip="${HOST_IP:-localhost}"

  echo "$running" | while read -r name; do
    local idx=${name#poste-}
    get_ports "$idx"

    cat > "$output_dir/email_config_instance_${idx}.json" << EOF
{
    "instance_id": ${idx},
    "email": "micheller@mcp.com",
    "password": "michelle_60R",
    "name": "Ronald Kelly",
    "imap_server": "${host_ip}",
    "imap_port": ${IMAP_PORT},
    "smtp_server": "${host_ip}",
    "smtp_port": ${SUBMISSION_PORT},
    "use_ssl": false,
    "use_starttls": false
}
EOF
  done

  # Generate a master index using jq
  local instance_count
  instance_count=$(echo "$running" | wc -l)

  # Merge all instance configs into one JSON array
  jq -s '{total_instances: length, host: "'"${host_ip}"'", instances: .}' \
    "$output_dir"/email_config_instance_*.json > "$output_dir/instances_index.json" 2>/dev/null || true

  echo "✅ Generated $instance_count instance configs in $output_dir/"
  echo "   Master index: $output_dir/instances_index.json"
}

# ── Main ────────────────────────────────────────────────────────────
COMMAND=${1:-help}

case "$COMMAND" in
  start)
    if [ -z "${2:-}" ]; then
      echo "Usage: $0 start <index>"
      exit 1
    fi
    full_setup_instance "$2"
    ;;
  stop)
    if [ -z "${2:-}" ]; then
      echo "Usage: $0 stop <index>"
      exit 1
    fi
    stop_instance "$2"
    ;;
  build_golden)
    build_golden
    ;;
  start_all)
    start_all "${2:-5}"
    ;;
  stop_all)
    stop_all "${2:-200}"
    ;;
  status)
    show_status
    ;;
  config)
    if [ -z "${2:-}" ]; then
      echo "Usage: $0 config <index>"
      exit 1
    fi
    configure_instance "$2"
    ;;
  generate_configs)
    generate_configs
    ;;
  help|*)
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  build_golden         Build golden image (setup once, reuse everywhere)"
    echo "  start <index>        Start a single instance by index (0-based)"
    echo "  stop <index>         Stop a single instance by index"
    echo "  start_all <count>    Start <count> instances from golden image (fast)"
    echo "  stop_all [count]     Stop all running instances"
    echo "  status               Show all running instances and their ports"
    echo "  config <index>       Reconfigure dovecot for an instance"
    echo "  generate_configs     Generate email_config JSON for all running instances"
    echo ""
    echo "Examples:"
    echo "  $0 build_golden      # Build golden image (~10min, only once)"
    echo "  $0 start_all 200     # Clone 200 instances from golden image (fast!)"
    echo "  $0 start_all 5       # Start 5 instances"
    echo "  $0 start 42          # Start just instance 42"
    echo "  $0 stop 42           # Stop instance 42"
    echo "  $0 stop_all          # Stop everything"
    echo "  $0 status            # See what's running"
    echo "  $0 generate_configs  # Generate email configs for all running instances"
    echo ""
    echo "Environment variables:"
    echo "  BASE_WEB=10005       Base web port (instance N = BASE + N)"
    echo "  BASE_SMTP=2525       Base SMTP port"
    echo "  BASE_IMAP=1143       Base IMAP port"
    echo "  BASE_SUBMISSION=1587 Base submission port"
    echo "  NUM_USERS=503        Users to create per instance"
    echo "  MAX_PARALLEL=10      Max parallel instance starts"
    echo "  HOST_IP=1.2.3.4      IP for generated configs (default: localhost)"
    echo ""
    echo "Port allocation (200 instances):"
    echo "  Web:        10005 - 10204"
    echo "  SMTP:       2525  - 2724"
    echo "  IMAP:       1143  - 1342"
    echo "  Submission: 1587  - 1786"
    exit 1
    ;;
esac

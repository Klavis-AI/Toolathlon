#!/bin/bash

# Batch create Poste.io users across multiple domains (mcp1.com .. mcp110.com)
# Reuses existing users from configs/users_data.json but replaces the domain part
# Does NOT create admin accounts — only regular users
#
# PERFORMANCE: Instead of one `docker exec` per user (slow due to process overhead),
# this script generates a single PHP script per domain and executes it in ONE
# `docker exec` call. This is ~50-100x faster (seconds per domain instead of minutes).
# Multiple domains are also processed in parallel.

# read out `podman_or_docker` from global_configs.py
podman_or_docker=$(uv run python -c "import sys; sys.path.append('configs'); from global_configs import global_configs; print(global_configs.podman_or_docker)")

# Read instance_suffix from ports_config.yaml
instance_suffix=$(uv run python -c "
import yaml
try:
    with open('configs/ports_config.yaml', 'r') as f:
        config = yaml.safe_load(f)
        print(config.get('instance_suffix', ''))
except:
    print('')
" 2>/dev/null || echo "")

CONTAINER_NAME="poste${instance_suffix}"
CONFIG_DIR="$(dirname "$0")/../configs"
ACCOUNTS_FILE="$CONFIG_DIR/created_accounts_multi_domain.json"

# Domain range
DOMAIN_START=${1:-1}
DOMAIN_END=${2:-110}

# Number of domains to process concurrently
# NOTE: Keep (MAX_CONCURRENT_DOMAINS × PARALLEL_WORKERS_PER_DOMAIN) reasonable
# for your machine. Each PHP worker uses ~30-50MB RAM. Too many concurrent
# writers can also cause SQLite lock contention inside Poste.io.
# Defaults tuned for e2-medium (1 vCPU, 4GB RAM): 3 × 5 = 15 peak PHP processes.
MAX_CONCURRENT_DOMAINS=${MAX_CONCURRENT_DOMAINS:-3}

# Number of parallel worker processes WITHIN each domain (Strategy B only)
# Each worker handles a chunk of users simultaneously inside the container.
# For Strategy A this is ignored (single PHP process handles all users).
PARALLEL_WORKERS_PER_DOMAIN=${PARALLEL_WORKERS_PER_DOMAIN:-5}

# Function to show usage
show_usage() {
    echo "Usage: $0 [domain_start] [domain_end]"
    echo "  domain_start: First domain number (default: 1 => mcp1.com)"
    echo "  domain_end:   Last domain number  (default: 110 => mcp110.com)"
    echo ""
    echo "Environment variables:"
    echo "  DEBUG=1                        # Show detailed error messages"
    echo "  MAX_CONCURRENT_DOMAINS=10      # Domains processed in parallel (default: 10)"
    echo "  PARALLEL_WORKERS_PER_DOMAIN=10 # Parallel workers within each domain (default: 10, Strategy B only)"
    echo ""
    echo "Example:"
    echo "  $0             # Create users for mcp1.com through mcp110.com"
    echo "  $0 1 10        # Create users for mcp1.com through mcp10.com"
    echo "  DEBUG=1 $0 5 5 # Create users for mcp5.com only, with debug output"
    echo "  MAX_CONCURRENT_DOMAINS=20 $0  # Process 20 domains in parallel"
    exit 1
}

# Validate arguments
if [[ "$DOMAIN_START" =~ ^-?[hH] ]]; then
    show_usage
fi
if ! [[ "$DOMAIN_START" =~ ^[0-9]+$ ]] || ! [[ "$DOMAIN_END" =~ ^[0-9]+$ ]]; then
    echo "Error: domain_start and domain_end must be positive integers."
    show_usage
fi
if [ "$DOMAIN_START" -gt "$DOMAIN_END" ]; then
    echo "Error: domain_start ($DOMAIN_START) must be <= domain_end ($DOMAIN_END)."
    show_usage
fi

# Load user count from JSON
TOTAL_JSON_USERS=$(jq '.users | length' configs/users_data.json 2>/dev/null || echo "0")
if [ "$TOTAL_JSON_USERS" -eq 0 ]; then
    echo "❌ Error: No users found in configs/users_data.json"
    exit 1
fi

TOTAL_DOMAINS=$((DOMAIN_END - DOMAIN_START + 1))
TOTAL_USERS_TO_CREATE=$((TOTAL_JSON_USERS * TOTAL_DOMAINS))

echo "🚀 Starting multi-domain batch user creation (optimized)..."
echo "🌐 Domains: mcp${DOMAIN_START}.com through mcp${DOMAIN_END}.com ($TOTAL_DOMAINS domains)"
echo "👤 Users per domain: $TOTAL_JSON_USERS"
echo "📊 Total users to create: $TOTAL_USERS_TO_CREATE"
echo "⚡ Parallel domains: $MAX_CONCURRENT_DOMAINS"
echo "⚡ Workers per domain: $PARALLEL_WORKERS_PER_DOMAIN (Strategy B)"
echo ""

# Check if container is running
if ! $podman_or_docker ps | grep -q "$CONTAINER_NAME"; then
    echo "❌ Error: Container $CONTAINER_NAME is not running"
    echo "Please run: ./setup.sh start"
    exit 1
fi

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

# Create temporary working directory
TEMP_DIR="$(dirname "$0")/../tmpfiles_multi"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Initialize JSON accounts file
echo "📄 Initializing accounts file: $ACCOUNTS_FILE"
cat > "$ACCOUNTS_FILE" << EOF
{
  "created_date": "$(date -Iseconds)",
  "domain_range": "mcp${DOMAIN_START}.com - mcp${DOMAIN_END}.com",
  "total_domains": $TOTAL_DOMAINS,
  "users_per_domain": $TOTAL_JSON_USERS,
  "domains": {},
  "statistics": {
    "domains_created": 0,
    "users_created": 0,
    "users_failed": 0
  }
}
EOF

# ──────────────────────────────────────────────────────────────────────
# STEP 1: Prepare user data and a reusable PHP batch-creation script.
#
# PERFORMANCE KEY INSIGHT:
# The old approach: 1 `docker exec` + 1 `php` process per user.
#   - docker exec overhead: ~100ms, PHP Symfony bootstrap: ~400ms
#   - 500 users × 110 domains = 55,000 invocations → ~7+ hours
#
# New approach: Generate a single PHP script that boots the Symfony
# application ONCE, then loops through ALL users for a domain.
# This reduces per-domain time from ~5 min to ~5-15 seconds.
# We also process multiple domains in parallel.
# ──────────────────────────────────────────────────────────────────────

echo "⚙️  Preparing user data..."

# Extract user local parts and metadata from JSON as a CSV for PHP to consume
# Format: local_part,password,full_name
USERS_CSV_FILE="$TEMP_DIR/users_data.csv"
jq -r '.users[] | "\(.email | split("@")[0]),\(.password),\(.full_name)"' \
    configs/users_data.json > "$USERS_CSV_FILE"

echo "✅ User data prepared ($TOTAL_JSON_USERS users)"
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 2: Create all domains first (parallel, fast — 110 calls max)
# ──────────────────────────────────────────────────────────────────────
echo "🌐 Creating $TOTAL_DOMAINS domains..."

# Get existing domains once
EXISTING_DOMAINS=$($podman_or_docker exec --user=8 $CONTAINER_NAME php /opt/admin/bin/console domain:list 2>/dev/null)

for domain_num in $(seq "$DOMAIN_START" "$DOMAIN_END"); do
    DOMAIN="mcp${domain_num}.com"
    if ! echo "$EXISTING_DOMAINS" | grep -q "$DOMAIN"; then
        $podman_or_docker exec --user=8 $CONTAINER_NAME php /opt/admin/bin/console domain:create "$DOMAIN" &>/dev/null &
    fi
    # Throttle domain creation: wait every 10
    if [ $(( (domain_num - DOMAIN_START + 1) % 10 )) -eq 0 ]; then
        wait
        printf "\r   Created domains up to mcp%d.com..."  "$domain_num"
    fi
done
wait
echo ""
echo "✅ All domains created"
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 3: Generate a PHP batch script that creates all users for a
#         given domain by booting the Symfony kernel ONCE.
#
# This PHP script:
#   1. Boots the Poste.io Symfony console Application
#   2. Reads users from a CSV file passed as argument
#   3. Runs the email:create command for each user in-process
#   4. Outputs "SUCCESS_COUNT|FAILED_COUNT" on the last line
# ──────────────────────────────────────────────────────────────────────

# --- Strategy A: Single-PHP-process approach (fastest) ---
# We generate a PHP script that boots the Symfony kernel once and loops.
# If the internal Poste.io class structure doesn't match, we detect it
# and fall back to Strategy B.

BATCH_PHP="$TEMP_DIR/batch_create_users.php"
cat > "$BATCH_PHP" << 'PHPEOF'
<?php
// Batch user creation script for Poste.io
// Usage: php batch_create_users.php <domain> <csv_file>
// CSV format (pipe-delimited): local_part|password|full_name
//
// Boots the Symfony Application ONCE and runs email:create for each
// user in-process, avoiding per-user PHP bootstrap overhead.

if ($argc < 3) {
    fwrite(STDERR, "Usage: php batch_create_users.php <domain> <csv_file>\n");
    exit(1);
}

$domain = $argv[1];
$csvFile = $argv[2];

// Boot the Poste.io Symfony console application
// Try multiple possible autoload/kernel paths
$autoloadPaths = [
    '/opt/admin/vendor/autoload.php',
    '/opt/admin/app/autoload.php',
];

$loaded = false;
foreach ($autoloadPaths as $path) {
    if (file_exists($path)) {
        require $path;
        $loaded = true;
        break;
    }
}
if (!$loaded) {
    fwrite(STDERR, "FALLBACK_NEEDED\n");
    echo "0|0\n";
    exit(2);
}

use Symfony\Component\Console\Input\ArrayInput;
use Symfony\Component\Console\Output\NullOutput;

// Try to find and boot the kernel
$application = null;
try {
    // Try standard Symfony kernel class names
    $kernelClasses = ['AppKernel', 'App\\Kernel', 'Kernel'];
    foreach ($kernelClasses as $kClass) {
        if (class_exists($kClass)) {
            $kernel = new $kClass('prod', false);
            $kernel->boot();
            $application = new \Symfony\Bundle\FrameworkBundle\Console\Application($kernel);
            $application->setAutoExit(false);
            break;
        }
    }

    // If no kernel found, try loading via the console bin directly
    if (!$application) {
        // Try to get application from the console entry point
        if (file_exists('/opt/admin/bin/console')) {
            // Read the console file to find how it boots
            $consoleContent = file_get_contents('/opt/admin/bin/console');
            // Look for kernel class reference
            if (preg_match('/new\s+([A-Za-z\\\\]+Kernel|[A-Za-z\\\\]+)\s*\(/', $consoleContent, $matches)) {
                $kClass = $matches[1];
                if (class_exists($kClass)) {
                    $kernel = new $kClass('prod', false);
                    $kernel->boot();
                    $application = new \Symfony\Bundle\FrameworkBundle\Console\Application($kernel);
                    $application->setAutoExit(false);
                }
            }
        }
    }
} catch (\Exception $e) {
    fwrite(STDERR, "Kernel boot failed: " . $e->getMessage() . "\n");
}

if (!$application) {
    fwrite(STDERR, "FALLBACK_NEEDED\n");
    echo "0|0\n";
    exit(2);
}

$output = new NullOutput();
$success = 0;
$failed = 0;

$handle = fopen($csvFile, 'r');
if (!$handle) {
    fwrite(STDERR, "Cannot open CSV file: $csvFile\n");
    echo "0|0\n";
    exit(1);
}

while (($line = fgets($handle)) !== false) {
    $line = trim($line);
    if (empty($line)) continue;

    // Parse pipe-delimited: local_part|password|full_name
    $parts = explode('|', $line, 3);
    if (count($parts) < 3) continue;

    $email = $parts[0] . '@' . $domain;
    $password = $parts[1];
    $fullName = $parts[2];

    try {
        $input = new ArrayInput([
            'command' => 'email:create',
            'email' => $email,
            'password' => $password,
            'name' => $fullName,
        ]);
        $exitCode = $application->run($input, $output);
        if ($exitCode === 0) {
            $success++;
        } else {
            $failed++;
        }
    } catch (\Exception $e) {
        $failed++;
    }
}
fclose($handle);

echo "$success|$failed\n";
PHPEOF

# --- Strategy B: Parallelized shell-loop fallback ---
# One docker exec per domain, splits users into N chunks, runs N parallel
# workers inside the container. Each worker processes its chunk sequentially.
# With 10 workers: ~50x faster than original (avoids docker exec overhead
# per user AND parallelizes the PHP calls within the container).
BATCH_SH="$TEMP_DIR/batch_create_users.sh"
cat > "$BATCH_SH" << 'SHEOF'
#!/bin/sh
# Usage: sh batch_create_users.sh <domain> <csv_file> <num_workers>
# Splits csv_file into <num_workers> chunks, runs them in parallel.
DOMAIN="$1"
CSV_FILE="$2"
NUM_WORKERS="${3:-10}"

TOTAL_LINES=$(wc -l < "$CSV_FILE")
if [ "$TOTAL_LINES" -eq 0 ]; then
    echo "0|0"
    exit 0
fi

# Calculate lines per chunk (ceiling division)
LINES_PER_CHUNK=$(( (TOTAL_LINES + NUM_WORKERS - 1) / NUM_WORKERS ))

# Split the CSV into chunks
TMP_PREFIX="/tmp/chunk_${DOMAIN}_"
split -l "$LINES_PER_CHUNK" -d -a 3 "$CSV_FILE" "$TMP_PREFIX"

# Worker function: process one chunk file, write result to a result file
process_chunk() {
    CHUNK_FILE="$1"
    RESULT_FILE="${CHUNK_FILE}.result"
    S=0
    F=0
    while IFS='|' read -r local_part password full_name; do
        [ -z "$local_part" ] && continue
        if php /opt/admin/bin/console email:create "${local_part}@${DOMAIN}" "$password" "$full_name" >/dev/null 2>&1; then
            S=$((S+1))
        else
            F=$((F+1))
        fi
    done < "$CHUNK_FILE"
    echo "${S}|${F}" > "$RESULT_FILE"
}

# Launch all workers in parallel
for chunk in ${TMP_PREFIX}*; do
    # Skip .result files
    case "$chunk" in *.result) continue ;; esac
    process_chunk "$chunk" &
done
wait

# Aggregate results from all chunks
TOTAL_SUCCESS=0
TOTAL_FAILED=0
for result in ${TMP_PREFIX}*.result; do
    if [ -f "$result" ]; then
        IFS='|' read -r s f < "$result"
        TOTAL_SUCCESS=$((TOTAL_SUCCESS + s))
        TOTAL_FAILED=$((TOTAL_FAILED + f))
    fi
done

# Clean up chunk files
rm -f ${TMP_PREFIX}*

echo "${TOTAL_SUCCESS}|${TOTAL_FAILED}"
SHEOF

# Use pipe-delimited format to avoid issues with commas in passwords/names
USERS_DATA_FILE="$TEMP_DIR/users_data.psv"
jq -r '.users[] | "\(.email | split("@")[0])|\(.password)|\(.full_name)"' \
    configs/users_data.json > "$USERS_DATA_FILE"

echo "⚙️  Uploading batch scripts and user data to container..."

# Copy scripts and data into the container once
$podman_or_docker cp "$BATCH_PHP" "$CONTAINER_NAME:/tmp/batch_create_users.php"
$podman_or_docker cp "$BATCH_SH" "$CONTAINER_NAME:/tmp/batch_create_users.sh"
$podman_or_docker cp "$USERS_DATA_FILE" "$CONTAINER_NAME:/tmp/users_data.psv"

# Test if the PHP batch approach works (exit code 2 = fallback needed)
echo "🔍 Testing PHP batch strategy..."
TEST_OUTPUT=$($podman_or_docker exec --user=8 "$CONTAINER_NAME" \
    php /tmp/batch_create_users.php "test.invalid" /tmp/users_data.psv 2>&1 | head -5)
TEST_EXIT=$?

USE_PHP_BATCH=true
if [ $TEST_EXIT -eq 2 ] || echo "$TEST_OUTPUT" | grep -q "FALLBACK_NEEDED"; then
    echo "⚠️  PHP batch approach not compatible with this Poste.io version."
    echo "   Using shell-loop fallback (still much faster than original)."
    USE_PHP_BATCH=false
else
    echo "✅ PHP batch strategy works — maximum speed mode!"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 4: Process each domain by running the batch script.
#         Multiple domains are processed in parallel.
#         Each domain = 1 docker exec call = all users created at once.
# ──────────────────────────────────────────────────────────────────────

# Function to process a single domain
process_domain() {
    local domain_num=$1
    local DOMAIN="mcp${domain_num}.com"
    local RESULT_FILE="$TEMP_DIR/domain_${domain_num}.result"

    local OUTPUT
    if [ "$USE_PHP_BATCH" = "true" ]; then
        # Strategy A: Single PHP process, Symfony kernel booted once
        OUTPUT=$($podman_or_docker exec --user=8 "$CONTAINER_NAME" \
            php /tmp/batch_create_users.php "$DOMAIN" /tmp/users_data.psv 2>/dev/null)
    else
        # Strategy B: Parallelized shell loop (1 docker exec, N workers inside)
        OUTPUT=$($podman_or_docker exec --user=8 "$CONTAINER_NAME" \
            sh /tmp/batch_create_users.sh "$DOMAIN" /tmp/users_data.psv "$PARALLEL_WORKERS_PER_DOMAIN" 2>/dev/null)
    fi

    # Parse output: last line should be "SUCCESS_COUNT|FAILED_COUNT"
    local RESULT_LINE
    RESULT_LINE=$(echo "$OUTPUT" | tail -1)
    local SUCCESS_COUNT FAILED_COUNT
    SUCCESS_COUNT=$(echo "$RESULT_LINE" | cut -d'|' -f1)
    FAILED_COUNT=$(echo "$RESULT_LINE" | cut -d'|' -f2)

    # Default to 0 if parsing failed
    SUCCESS_COUNT=${SUCCESS_COUNT:-0}
    FAILED_COUNT=${FAILED_COUNT:-0}

    # Write domain result
    echo "${domain_num}|${DOMAIN}|${SUCCESS_COUNT}|${FAILED_COUNT}" > "$RESULT_FILE"

    echo "  ✅ $DOMAIN: $SUCCESS_COUNT created, $FAILED_COUNT failed"
}

echo "👥 Creating users across $TOTAL_DOMAINS domains ($MAX_CONCURRENT_DOMAINS in parallel)..."
echo ""

BATCH_COUNT=0
for domain_num in $(seq "$DOMAIN_START" "$DOMAIN_END"); do
    process_domain "$domain_num" &
    BATCH_COUNT=$((BATCH_COUNT + 1))

    # Throttle: wait for batch to complete
    if [ $((BATCH_COUNT % MAX_CONCURRENT_DOMAINS)) -eq 0 ]; then
        wait
        COMPLETED=$((domain_num - DOMAIN_START + 1))
        echo "  --- Progress: $COMPLETED / $TOTAL_DOMAINS domains done ---"
    fi
done
wait
echo ""

# Clean up container temp files
$podman_or_docker exec "$CONTAINER_NAME" rm -f /tmp/batch_create_users.php /tmp/batch_create_users.sh /tmp/users_data.psv 2>/dev/null &

# ──────────────────────────────────────────────────────────────────────
# STEP 5: Aggregate results and build the accounts JSON
# ──────────────────────────────────────────────────────────────────────
echo "📊 Aggregating results..."

GLOBAL_SUCCESS=0
GLOBAL_FAILED=0
DOMAINS_CREATED=0

for result_file in "$TEMP_DIR"/domain_*.result; do
    if [ -f "$result_file" ]; then
        IFS='|' read -r dnum domain sc fc < "$result_file"
        GLOBAL_SUCCESS=$((GLOBAL_SUCCESS + sc))
        GLOBAL_FAILED=$((GLOBAL_FAILED + fc))
        ((DOMAINS_CREATED++))
    fi
done

# Build a comprehensive accounts JSON using the users data + results
# For each domain, generate the user list with the domain-specific emails
echo "💾 Building accounts JSON..."
python3 -c "
import json, sys

# Load user data
with open('configs/users_data.json') as f:
    users = json.load(f)['users']

# Load result files
import glob, os
results = {}
for rf in glob.glob('$TEMP_DIR/domain_*.result'):
    with open(rf) as f:
        parts = f.read().strip().split('|')
        if len(parts) == 4:
            results[parts[1]] = {'success': int(parts[2]), 'failed': int(parts[3])}

# Build output
output = {
    'created_date': '$(date -Iseconds)',
    'domain_range': 'mcp${DOMAIN_START}.com - mcp${DOMAIN_END}.com',
    'total_domains': $TOTAL_DOMAINS,
    'users_per_domain': len(users),
    'domains': {},
    'statistics': {
        'domains_created': $DOMAINS_CREATED,
        'users_created': $GLOBAL_SUCCESS,
        'users_failed': $GLOBAL_FAILED
    }
}

for domain_num in range($DOMAIN_START, $DOMAIN_END + 1):
    domain = f'mcp{domain_num}.com'
    domain_users = []
    for u in users:
        local_part = u['email'].split('@')[0]
        domain_users.append({
            'email': f'{local_part}@{domain}',
            'password': u['password'],
            'name': u['full_name'],
            'first_name': u['first_name'],
            'last_name': u['last_name']
        })
    output['domains'][domain] = domain_users

with open('$ACCOUNTS_FILE', 'w') as f:
    json.dump(output, f, indent=2)

print(f'Saved {len(output[\"domains\"])} domains to accounts file')
" 2>&1

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Multi-domain user creation completed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Final Statistics:"
echo "   🌐 Domains processed: $DOMAINS_CREATED"
echo "   ✅ Users created:     $GLOBAL_SUCCESS"
echo "   ❌ Users failed:      $GLOBAL_FAILED"
echo "   📊 Total attempted:   $((GLOBAL_SUCCESS + GLOBAL_FAILED))"
echo ""
echo "📄 Account details saved in: $ACCOUNTS_FILE"
echo "✨ Script execution completed!"

#!/bin/bash
#
# setup_gce_vm.sh — Provision a GCE VM for running multiple Poste.io instances.
#
# This script:
#   1. Creates a GCE VM with sufficient RAM for N Poste instances
#   2. Opens firewall rules for the port ranges
#   3. Installs Docker on the VM
#   4. Optionally pulls the Poste.io image
#
# Usage:
#   bash setup_gce_vm.sh create [instance_count]    # Create VM + firewall
#   bash setup_gce_vm.sh delete                     # Delete VM + firewall
#   bash setup_gce_vm.sh ssh                        # SSH into the VM
#   bash setup_gce_vm.sh info                       # Show VM IP and status
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - A GCP project set: gcloud config set project <PROJECT_ID>

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
VM_NAME="${VM_NAME:-poste-multi}"
ZONE="${ZONE:-us-central1-a}"
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
FIREWALL_RULE_NAME="${FIREWALL_RULE_NAME:-allow-poste-ports}"

# Port ranges (must match setup_multi.sh BASE_ values)
BASE_WEB=10005
BASE_SMTP=2525
BASE_IMAP=1143
BASE_SUBMISSION=1587

# ── Compute VM size based on instance count ──────────────────────────
choose_machine_type() {
  local count=${1:-5}

  # Each Poste instance ~250MB RAM (with ClamAV/Rspamd disabled)
  # Add 2GB headroom for OS + Docker
  local ram_needed=$(( count * 250 + 2000 ))
  local ram_gb=$(( (ram_needed + 1023) / 1024 ))  # round up to GB

  echo "📊 Estimated RAM needed: ${ram_needed}MB (~${ram_gb}GB) for $count instances" >&2

  if [ $ram_gb -le 4 ]; then
    echo "e2-highmem-2"    # 2 vCPU, 16 GB — handles up to ~50 instances
  elif [ $ram_gb -le 16 ]; then
    echo "e2-highmem-2"    # 2 vCPU, 16 GB
  elif [ $ram_gb -le 32 ]; then
    echo "e2-highmem-4"    # 4 vCPU, 32 GB — handles up to ~120 instances
  elif [ $ram_gb -le 64 ]; then
    echo "e2-highmem-8"    # 8 vCPU, 64 GB — handles up to ~240 instances
  else
    echo "e2-highmem-16"   # 16 vCPU, 128 GB
  fi
}

# ── Compute port ranges ─────────────────────────────────────────────
get_port_ranges() {
  local count=${1:-200}
  local max_idx=$((count - 1))

  local web_end=$((BASE_WEB + max_idx))
  local smtp_end=$((BASE_SMTP + max_idx))
  local imap_end=$((BASE_IMAP + max_idx))
  local sub_end=$((BASE_SUBMISSION + max_idx))

  echo "${BASE_IMAP}-${imap_end},${BASE_SUBMISSION}-${sub_end},${BASE_SMTP}-${smtp_end},${BASE_WEB}-${web_end}"
}

# ── Create VM ────────────────────────────────────────────────────────
create_vm() {
  local count=${1:-5}
  local machine_type=$(choose_machine_type "$count")

  echo "🖥️  Creating VM: $VM_NAME"
  echo "   Machine type: $machine_type"
  echo "   Zone: $ZONE"
  echo "   Project: $PROJECT"
  echo ""

  # Create the VM
  gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --machine-type="$machine_type" \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=100GB \
    --boot-disk-type=pd-ssd \
    --tags=poste-server \
    --metadata=startup-script='#!/bin/bash
# Install Docker
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq docker.io jq
  systemctl enable docker
  systemctl start docker
  usermod -aG docker $(logname 2>/dev/null || echo "ubuntu")
fi
# Pull Poste.io image
docker pull analogic/poste.io:2.5.5
echo "VM setup complete" > /tmp/vm_setup_done
'

  echo ""
  echo "✅ VM created. Waiting for it to be ready..."
  sleep 10

  # Create firewall rule
  create_firewall "$count"

  # Wait for startup script
  echo "⏳ Waiting for Docker installation (this takes ~60 seconds)..."
  for i in $(seq 1 30); do
    if gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --command="test -f /tmp/vm_setup_done" 2>/dev/null; then
      echo "✅ VM is ready!"
      break
    fi
    sleep 5
    printf "."
  done
  echo ""

  # Show connection info
  show_info
}

# ── Create firewall rule ────────────────────────────────────────────
create_firewall() {
  local count=${1:-200}
  local port_ranges=$(get_port_ranges "$count")

  echo "🔥 Creating firewall rule: $FIREWALL_RULE_NAME"
  echo "   Ports: $port_ranges"

  # Delete existing rule if present
  gcloud compute firewall-rules delete "$FIREWALL_RULE_NAME" \
    --project="$PROJECT" --quiet 2>/dev/null || true

  gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
    --project="$PROJECT" \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules="tcp:${BASE_IMAP}-$((BASE_IMAP + count - 1)),tcp:${BASE_SUBMISSION}-$((BASE_SUBMISSION + count - 1)),tcp:${BASE_SMTP}-$((BASE_SMTP + count - 1)),tcp:${BASE_WEB}-$((BASE_WEB + count - 1))" \
    --target-tags=poste-server \
    --source-ranges=0.0.0.0/0 \
    --description="Allow traffic to Poste.io multi-instance ports (${count} instances)"

  echo "✅ Firewall rule created"
}

# ── Delete VM and firewall ──────────────────────────────────────────
delete_vm() {
  echo "🗑️  Deleting VM: $VM_NAME"
  gcloud compute instances delete "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" --quiet 2>/dev/null || true

  echo "🗑️  Deleting firewall rule: $FIREWALL_RULE_NAME"
  gcloud compute firewall-rules delete "$FIREWALL_RULE_NAME" \
    --project="$PROJECT" --quiet 2>/dev/null || true

  echo "✅ Cleaned up"
}

# ── SSH into VM ─────────────────────────────────────────────────────
ssh_vm() {
  gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" -- "${@:2}"
}

# ── Show info ────────────────────────────────────────────────────────
show_info() {
  echo ""
  echo "📋 VM Information:"
  echo "─────────────────────────────────────────────"

  local ip
  ip=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "unknown")

  local status
  status=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" \
    --format='get(status)' 2>/dev/null || echo "unknown")

  local machine_type
  machine_type=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" \
    --format='get(machineType)' 2>/dev/null | awk -F/ '{print $NF}' || echo "unknown")

  echo "  Name:         $VM_NAME"
  echo "  Status:       $status"
  echo "  Machine type: $machine_type"
  echo "  External IP:  $ip"
  echo "  Zone:         $ZONE"
  echo ""
  echo "  SSH:  gcloud compute ssh $VM_NAME --zone=$ZONE"
  echo ""
  echo "  To start instances on the VM:"
  echo "    1. SSH into VM"
  echo "    2. Clone your repo"
  echo "    3. Run: bash deployment/poste/scripts/setup_multi.sh start_all 200"
  echo "    4. Generate configs: HOST_IP=$ip bash deployment/poste/scripts/setup_multi.sh generate_configs"
  echo ""
  echo "  Port ranges (for 200 instances):"
  echo "    Web:        ${BASE_WEB} - $((BASE_WEB + 199))"
  echo "    SMTP:       ${BASE_SMTP} - $((BASE_SMTP + 199))"
  echo "    IMAP:       ${BASE_IMAP} - $((BASE_IMAP + 199))"
  echo "    Submission: ${BASE_SUBMISSION} - $((BASE_SUBMISSION + 199))"
}

# ── Resize VM ────────────────────────────────────────────────────────
resize_vm() {
  local count=${1:-200}
  local machine_type=$(choose_machine_type "$count")

  echo "🔄 Resizing VM to $machine_type for $count instances..."
  echo "   This requires stopping the VM temporarily."

  gcloud compute instances stop "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT"

  gcloud compute instances set-machine-type "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" \
    --machine-type="$machine_type"

  gcloud compute instances start "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT"

  echo "✅ VM resized to $machine_type and restarted"
  show_info
}

# ── Main ─────────────────────────────────────────────────────────────
COMMAND=${1:-help}

case "$COMMAND" in
  create)
    create_vm "${2:-5}"
    ;;
  delete)
    delete_vm
    ;;
  ssh)
    ssh_vm "$@"
    ;;
  info)
    show_info
    ;;
  firewall)
    create_firewall "${2:-200}"
    ;;
  resize)
    resize_vm "${2:-200}"
    ;;
  help|*)
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  create [count]    Create a GCE VM sized for <count> instances (default: 5)"
    echo "  delete            Delete the VM and firewall rules"
    echo "  ssh               SSH into the VM"
    echo "  info              Show VM IP, status, and connection info"
    echo "  firewall [count]  Update firewall rules for <count> instances"
    echo "  resize [count]    Resize VM for <count> instances (stops/starts VM)"
    echo ""
    echo "Examples:"
    echo "  $0 create 5       # Small VM for 5 instances (~\$49/mo)"
    echo "  $0 create 50      # Medium VM for 50 instances (~\$100/mo)"
    echo "  $0 create 200     # Large VM for 200 instances (~\$340/mo)"
    echo "  $0 resize 200     # Resize existing VM for 200 instances"
    echo "  $0 ssh             # SSH into the VM"
    echo "  $0 delete          # Tear everything down"
    echo ""
    echo "Environment variables:"
    echo "  VM_NAME=poste-multi          VM name"
    echo "  ZONE=us-central1-a           GCE zone"
    echo "  PROJECT=my-project           GCP project"
    echo "  FIREWALL_RULE_NAME=allow-poste-ports"
    echo ""
    echo "Estimated monthly costs (on-demand, us-central1):"
    echo "  5 instances:   e2-highmem-2  (16 GB)  ~\$75/mo"
    echo "  50 instances:  e2-highmem-4  (32 GB)  ~\$170/mo"
    echo "  200 instances: e2-highmem-8  (64 GB)  ~\$340/mo"
    exit 1
    ;;
esac

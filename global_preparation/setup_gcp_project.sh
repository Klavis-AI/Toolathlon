#!/bin/bash

# =============================================================================
# Google Cloud Project Setup Script
# =============================================================================
# This script automates the following:
# 1. Create a Google Cloud project with the given name
# 2. Enable the Compute Engine API in the project
# 3. Set <project_name>@klavis.cc as the project owner
#
# Usage:
#   bash global_preparation/setup_gcp_project.sh [--skip-create] <project_name>
#   bash global_preparation/setup_gcp_project.sh [--skip-create]   (reads from idlist.txt)
#
# Options:
#   --skip-create   Skip project creation (steps 2-4 only on existing projects)
# =============================================================================

set -e  # Exit on error

# Parse --skip-create flag
SKIP_CREATE=false
if [ "$1" == "--skip-create" ]; then
    SKIP_CREATE=true
    shift
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}       Google Cloud Project Setup${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

# =============================================================================
# Step 0: Validate arguments and check prerequisites
# =============================================================================
# echo -e "${YELLOW}[Step 0]${NC} Checking prerequisites..."

# # Check for gcloud CLI
# if ! command -v gcloud &> /dev/null; then
#     echo -e "${RED}ERROR: gcloud CLI not found!${NC}"
#     echo "Please install it first: https://cloud.google.com/sdk/docs/install"
#     exit 1
# fi

# # Check if logged in to gcloud
# if ! gcloud auth list --format="value(account)" | grep -q .; then
#     echo -e "${YELLOW}Not logged in to Google Cloud. Initiating login...${NC}"
#     gcloud auth login
# else
#     CURRENT_ACCOUNT=$(gcloud auth list --format='value(account)' --filter=status:ACTIVE)
#     echo -e "${GREEN}✓ Currently logged in as: ${BLUE}$CURRENT_ACCOUNT${NC}"
# fi

# echo ""
# echo -e "${GREEN}✓ Prerequisites check passed${NC}"
# echo ""

# =============================================================================
# Function to set up a single project
# =============================================================================
setup_project() {
    local PROJECT_NAME="$1"
    local OWNER_EMAIL="${PROJECT_NAME}@klavis.cc"

    echo -e "${BLUE}----------------------------------------------------------------${NC}"
    echo -e "  Project name: ${BLUE}$PROJECT_NAME${NC}"
    echo -e "  Owner email:  ${BLUE}$OWNER_EMAIL${NC}"
    echo -e "${BLUE}----------------------------------------------------------------${NC}"
    echo ""

    # Step 1: Create Google Cloud Project (or find existing)
    local PROJECT_ID
    local EXISTING_PROJECT
    EXISTING_PROJECT=$(gcloud projects list --filter="name=$PROJECT_NAME" --format="value(projectId)" --limit=1 2>/dev/null)

    if [ "$SKIP_CREATE" == "true" ]; then
        echo -e "${YELLOW}[Step 1]${NC} Skipping project creation (--skip-create)..."
        if [ -z "$EXISTING_PROJECT" ]; then
            echo -e "${RED}ERROR: No existing project found with name '$PROJECT_NAME'. Cannot skip creation.${NC}"
            exit 1
        fi
        PROJECT_ID="$EXISTING_PROJECT"
        echo -e "  Found existing project ID: ${BLUE}$PROJECT_ID${NC}"
    else
        echo -e "${YELLOW}[Step 1]${NC} Creating Google Cloud project: ${BLUE}$PROJECT_NAME${NC}..."

        if [ -n "$EXISTING_PROJECT" ]; then
            echo -e "${YELLOW}⚠ Project with name '$PROJECT_NAME' already exists (ID: $EXISTING_PROJECT). Skipping.${NC}"
            echo ""
            return 0
        fi

        PROJECT_ID="${PROJECT_NAME}-toolathlon"
        echo -e "  Project ID: ${BLUE}$PROJECT_ID${NC}"

        if gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME" 2>&1; then
            echo -e "${GREEN}✓ Project created successfully${NC}"
        else
            echo -e "${RED}ERROR: Failed to create project '$PROJECT_ID'${NC}"
            exit 1
        fi
    fi

    # Set as the active project
    gcloud config set project "$PROJECT_ID"
    echo -e "${GREEN}✓ Set '$PROJECT_ID' as the active project${NC}"
    echo ""

    # Step 2: Link billing account
    echo -e "${YELLOW}[Step 2]${NC} Checking billing status..."

    BILLING_ACCOUNT=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingAccountName)" 2>/dev/null)

    if [ -z "$BILLING_ACCOUNT" ] || [ "$BILLING_ACCOUNT" == "" ]; then
        echo -e "${YELLOW}No billing account linked. Searching for available billing accounts...${NC}"

        BILLING_ACCOUNTS=$(gcloud billing accounts list --format="value(name,displayName)" 2>/dev/null)

        if [ -z "$BILLING_ACCOUNTS" ]; then
            echo -e "${RED}ERROR: No billing accounts found!${NC}"
            echo "Please create a billing account at: https://console.cloud.google.com/billing"
            exit 1
        fi

        BILLING_ACCOUNT_ID=$(gcloud billing accounts list --format="value(name)" --limit=1 2>/dev/null)

        echo -e "  Linking billing account: ${BLUE}$BILLING_ACCOUNT_ID${NC}"
        gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID"
        echo -e "${GREEN}✓ Billing account linked${NC}"
    else
        echo -e "${GREEN}✓ Billing already enabled${NC}"
        echo -e "  Billing Account: ${BLUE}$(basename $BILLING_ACCOUNT)${NC}"
    fi

    echo ""

    # Step 3: Enable Compute Engine API
    echo -e "${YELLOW}[Step 3]${NC} Enabling Compute Engine API..."

    gcloud services enable compute.googleapis.com --project="$PROJECT_ID"

    echo -e "${GREEN}✓ Compute Engine API enabled${NC}"
    echo ""

    # Step 4: Set project owner
    echo -e "${YELLOW}[Step 4]${NC} Setting ${BLUE}$OWNER_EMAIL${NC} as project owner..."

    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="user:$OWNER_EMAIL" \
        --role="roles/owner" \
        --quiet

    echo -e "${GREEN}✓ Owner role granted to $OWNER_EMAIL${NC}"
    echo ""

    echo -e "${GREEN}✓ Setup complete for project: $PROJECT_NAME (ID: $PROJECT_ID)${NC}"
    echo ""
}

# =============================================================================
# Main: process single argument or read from idlist.txt
# =============================================================================
if [ -n "$1" ]; then
    setup_project "$1"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    IDLIST="$SCRIPT_DIR/idlist.txt"

    if [ ! -f "$IDLIST" ]; then
        echo -e "${RED}ERROR: No project name provided and $IDLIST not found.${NC}"
        echo ""
        echo "Usage: bash $0 <project_name>"
        echo "   or: place project names in idlist.txt (one per line)"
        exit 1
    fi

    TOTAL=$(grep -c . "$IDLIST" || true)
    COUNT=0

    echo -e "${BLUE}Reading project names from: $IDLIST ($TOTAL entries)${NC}"
    echo ""

    while IFS= read -r PROJECT_NAME || [ -n "$PROJECT_NAME" ]; do
        [[ -z "$PROJECT_NAME" || "$PROJECT_NAME" == \#* ]] && continue
        COUNT=$((COUNT + 1))
        echo -e "${BLUE}>>> [$COUNT/$TOTAL] Processing: $PROJECT_NAME${NC}"
        setup_project "$PROJECT_NAME"
    done < "$IDLIST"

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}       All done! Processed $COUNT projects.${NC}"
    echo -e "${GREEN}================================================================${NC}"
fi

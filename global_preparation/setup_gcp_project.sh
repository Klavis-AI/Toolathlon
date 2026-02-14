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
#   bash global_preparation/setup_gcp_project.sh <project_name>
# =============================================================================

set -e  # Exit on error

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
echo -e "${YELLOW}[Step 0]${NC} Checking prerequisites..."

# Check that project name was provided
if [ -z "$1" ]; then
    echo -e "${RED}ERROR: Project name is required!${NC}"
    echo ""
    echo "Usage: bash global_preparation/setup_gcp_project.sh <project_name>"
    exit 1
fi

PROJECT_NAME="$1"
OWNER_EMAIL="${PROJECT_NAME}@klavis.cc"

echo -e "  Project name: ${BLUE}$PROJECT_NAME${NC}"
echo -e "  Owner email:  ${BLUE}$OWNER_EMAIL${NC}"
echo ""

# Check for gcloud CLI
if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}ERROR: gcloud CLI not found!${NC}"
    echo "Please install it first: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Check if logged in to gcloud
if ! gcloud auth list --format="value(account)" | grep -q .; then
    echo -e "${YELLOW}Not logged in to Google Cloud. Initiating login...${NC}"
    gcloud auth login
else
    CURRENT_ACCOUNT=$(gcloud auth list --format='value(account)' --filter=status:ACTIVE)
    echo -e "${GREEN}✓ Currently logged in as: ${BLUE}$CURRENT_ACCOUNT${NC}"
fi

echo ""
echo -e "${GREEN}✓ Prerequisites check passed${NC}"
echo ""

# =============================================================================
# Step 1: Create Google Cloud Project
# =============================================================================
echo -e "${YELLOW}[Step 1]${NC} Creating Google Cloud project: ${BLUE}$PROJECT_NAME${NC}..."

if gcloud projects describe "$PROJECT_NAME" &> /dev/null; then
    echo -e "${YELLOW}⚠ Project '$PROJECT_NAME' already exists. Skipping creation.${NC}"
else
    if gcloud projects create "$PROJECT_NAME" --name="$PROJECT_NAME" 2>&1; then
        echo -e "${GREEN}✓ Project created successfully${NC}"
    else
        echo -e "${RED}ERROR: Failed to create project '$PROJECT_NAME'${NC}"
        echo "The project ID might already exist or be invalid."
        exit 1
    fi
fi

# Set as the active project
gcloud config set project "$PROJECT_NAME"
echo -e "${GREEN}✓ Set '$PROJECT_NAME' as the active project${NC}"
echo ""

# =============================================================================
# Step 2: Link billing account
# =============================================================================
echo -e "${YELLOW}[Step 2]${NC} Checking billing status..."

BILLING_ACCOUNT=$(gcloud billing projects describe "$PROJECT_NAME" --format="value(billingAccountName)" 2>/dev/null)

if [ -z "$BILLING_ACCOUNT" ] || [ "$BILLING_ACCOUNT" == "" ]; then
    echo -e "${YELLOW}No billing account linked. Searching for available billing accounts...${NC}"

    # List available billing accounts
    BILLING_ACCOUNTS=$(gcloud billing accounts list --format="value(name,displayName)" 2>/dev/null)

    if [ -z "$BILLING_ACCOUNTS" ]; then
        echo -e "${RED}ERROR: No billing accounts found!${NC}"
        echo "Please create a billing account at: https://console.cloud.google.com/billing"
        exit 1
    fi

    # Get the first available billing account
    BILLING_ACCOUNT_ID=$(gcloud billing accounts list --format="value(name)" --limit=1 2>/dev/null)

    echo -e "  Linking billing account: ${BLUE}$BILLING_ACCOUNT_ID${NC}"
    gcloud billing projects link "$PROJECT_NAME" --billing-account="$BILLING_ACCOUNT_ID"
    echo -e "${GREEN}✓ Billing account linked${NC}"
else
    echo -e "${GREEN}✓ Billing already enabled${NC}"
    echo -e "  Billing Account: ${BLUE}$(basename $BILLING_ACCOUNT)${NC}"
fi

echo ""

# =============================================================================
# Step 3: Enable Compute Engine API
# =============================================================================
echo -e "${YELLOW}[Step 3]${NC} Enabling Compute Engine API..."

gcloud services enable compute.googleapis.com --project="$PROJECT_NAME"

echo -e "${GREEN}✓ Compute Engine API enabled${NC}"
echo ""

# =============================================================================
# Step 4: Set project owner
# =============================================================================
echo -e "${YELLOW}[Step 4]${NC} Setting ${BLUE}$OWNER_EMAIL${NC} as project owner..."

gcloud projects add-iam-policy-binding "$PROJECT_NAME" \
    --member="user:$OWNER_EMAIL" \
    --role="roles/owner" \
    --quiet

echo -e "${GREEN}✓ Owner role granted to $OWNER_EMAIL${NC}"
echo ""

# =============================================================================
# Summary
# =============================================================================
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}       Setup Complete!${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Project ID:         ${BLUE}$PROJECT_NAME${NC}"
echo -e "  ${GREEN}✓${NC} Billing:            ${BLUE}Linked${NC}"
echo -e "  ${GREEN}✓${NC} Compute Engine API: ${BLUE}Enabled${NC}"
echo -e "  ${GREEN}✓${NC} Project Owner:      ${BLUE}$OWNER_EMAIL${NC}"
echo ""

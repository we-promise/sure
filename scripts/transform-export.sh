#!/bin/bash
# ===========================================================================
# Transform Old Export to Import-Compatible Format
# ===========================================================================
#
# This script transforms Sure export files from the old format to the new
# import-compatible format.
#
# Usage:
#   ./scripts/transform-export.sh <export_directory>
#
# Example:
#   ./scripts/transform-export.sh ./data/backups/sure_export_20260119_181110
#
# Output:
#   Creates a new directory with "_importable" suffix containing transformed files
#
# ===========================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check arguments
if [ -z "$1" ]; then
    log_error "Usage: $0 <export_directory>"
    echo ""
    echo "Example:"
    echo "  $0 ./data/backups/sure_export_20260119_181110"
    exit 1
fi

SOURCE_DIR="$1"
OUTPUT_DIR="${SOURCE_DIR}_importable"

# Validate source directory
if [ ! -d "$SOURCE_DIR" ]; then
    log_error "Directory not found: $SOURCE_DIR"
    exit 1
fi

log_info "Transforming export from: $SOURCE_DIR"
log_info "Output directory: $OUTPUT_DIR"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Transform accounts.csv
# Old: id,name,type,subtype,balance,currency,created_at
# New: account_type,name,balance,currency,balance_date
if [ -f "$SOURCE_DIR/accounts.csv" ]; then
    log_info "Transforming accounts.csv..."

    # Write new header
    echo "account_type,name,balance,currency,balance_date" > "$OUTPUT_DIR/accounts.csv"

    # Transform data rows (skip header, reorder columns)
    # Old columns: 1=id, 2=name, 3=type, 4=subtype, 5=balance, 6=currency, 7=created_at
    # New columns: type(3), name(2), balance(5), currency(6), created_at(7) as date
    tail -n +2 "$SOURCE_DIR/accounts.csv" | while IFS=, read -r id name type subtype balance currency created_at; do
        # Extract just the date part from ISO timestamp (e.g., 2026-01-15T21:48:57-06:00 -> 2026-01-15)
        balance_date=$(echo "$created_at" | cut -d'T' -f1)
        echo "$type,$name,$balance,$currency,$balance_date"
    done >> "$OUTPUT_DIR/accounts.csv"

    log_success "accounts.csv transformed ($(tail -n +2 "$OUTPUT_DIR/accounts.csv" | wc -l | tr -d ' ') rows)"
else
    log_warn "accounts.csv not found, skipping"
fi

# Transform transactions.csv
# Old: date,account_name,amount,name,category,tags,notes,currency
# New: date,amount,name,currency,category,tags,account,notes
if [ -f "$SOURCE_DIR/transactions.csv" ]; then
    log_info "Transforming transactions.csv..."

    # Write new header
    echo "date,amount,name,currency,category,tags,account,notes" > "$OUTPUT_DIR/transactions.csv"

    # Use awk for more robust CSV handling with potential commas in fields
    awk -F',' 'NR>1 {
        # Old: date(1),account_name(2),amount(3),name(4),category(5),tags(6),notes(7),currency(8)
        # New: date,amount,name,currency,category,tags,account,notes

        date=$1
        account=$2
        amount=$3
        name=$4
        category=$5
        tags=$6
        notes=$7
        currency=$8

        # Replace comma separator in tags with pipe
        gsub(/,/, "|", tags)

        # Output in new order
        print date","amount","name","currency","category","tags","account","notes
    }' "$SOURCE_DIR/transactions.csv" >> "$OUTPUT_DIR/transactions.csv"

    log_success "transactions.csv transformed ($(tail -n +2 "$OUTPUT_DIR/transactions.csv" | wc -l | tr -d ' ') rows)"
else
    log_warn "transactions.csv not found, skipping"
fi

# Transform trades.csv
# Old: date,account_name,ticker,quantity,price,amount,currency
# New: date,ticker,exchange_operating_mic,currency,qty,price,account,name
if [ -f "$SOURCE_DIR/trades.csv" ]; then
    log_info "Transforming trades.csv..."

    # Write new header
    echo "date,ticker,exchange_operating_mic,currency,qty,price,account,name" > "$OUTPUT_DIR/trades.csv"

    # Transform data rows
    # Old: date(1),account_name(2),ticker(3),quantity(4),price(5),amount(6),currency(7)
    # New: date,ticker,exchange_operating_mic(empty),currency,qty,price,account,name(empty)
    tail -n +2 "$SOURCE_DIR/trades.csv" | while IFS=, read -r date account_name ticker quantity price amount currency; do
        # exchange_operating_mic and name are empty in old format
        echo "$date,$ticker,,$currency,$quantity,$price,$account_name,"
    done >> "$OUTPUT_DIR/trades.csv"

    log_success "trades.csv transformed ($(tail -n +2 "$OUTPUT_DIR/trades.csv" | wc -l | tr -d ' ') rows)"
else
    log_warn "trades.csv not found, skipping"
fi

# Copy categories.csv as-is (format already matches)
if [ -f "$SOURCE_DIR/categories.csv" ]; then
    log_info "Copying categories.csv (format already compatible)..."
    cp "$SOURCE_DIR/categories.csv" "$OUTPUT_DIR/categories.csv"
    log_success "categories.csv copied ($(tail -n +2 "$OUTPUT_DIR/categories.csv" | wc -l | tr -d ' ') rows)"
else
    log_warn "categories.csv not found, skipping"
fi

# Copy rules.csv as-is (format already matches)
if [ -f "$SOURCE_DIR/rules.csv" ]; then
    log_info "Copying rules.csv (format already compatible)..."
    cp "$SOURCE_DIR/rules.csv" "$OUTPUT_DIR/rules.csv"
    log_success "rules.csv copied ($(tail -n +2 "$OUTPUT_DIR/rules.csv" | wc -l | tr -d ' ') rows)"
else
    log_warn "rules.csv not found, skipping"
fi

# Copy all.ndjson for reference (no importer yet, but preserved)
if [ -f "$SOURCE_DIR/all.ndjson" ]; then
    log_info "Copying all.ndjson (preserved for future use)..."
    cp "$SOURCE_DIR/all.ndjson" "$OUTPUT_DIR/all.ndjson"
    log_success "all.ndjson copied"
fi

echo ""
log_success "Transformation complete!"
echo ""
echo "Transformed files are in: $OUTPUT_DIR"
echo ""
echo "Import order (recommended):"
echo "  1. categories.csv  - Import as Category Import"
echo "  2. accounts.csv    - Import as Account Import"
echo "  3. transactions.csv - Import as Transaction Import"
echo "  4. trades.csv      - Import as Trade Import (if you have trades)"
echo "  5. rules.csv       - Import as Rule Import"
echo ""
echo "Note: When importing, you may still need to map columns in the UI."
echo "The new format should auto-detect most columns correctly."

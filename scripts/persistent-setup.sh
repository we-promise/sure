#!/bin/bash
# ===========================================================================
# Persistent Storage Setup Script
# ===========================================================================
#
# This script sets up host-based persistent storage for Sure that survives
# Docker daemon issues, crashes, or reinstalls.
#
# Usage:
#   ./scripts/persistent-setup.sh          # Setup and start
#   ./scripts/persistent-setup.sh start    # Start services
#   ./scripts/persistent-setup.sh stop     # Stop services
#   ./scripts/persistent-setup.sh logs     # View logs
#   ./scripts/persistent-setup.sh backup   # Backup data
#   ./scripts/persistent-setup.sh status   # Check status
#
# ===========================================================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="${DATA_DIR:-$PROJECT_DIR/data}"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.persistent.yml"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Docker is running
check_docker() {
    if ! docker info > /dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi
    log_success "Docker is running"
}

# Create data directories with proper permissions
setup_directories() {
    log_info "Setting up persistent data directories at: $DATA_DIR"

    mkdir -p "$DATA_DIR/postgres"
    mkdir -p "$DATA_DIR/redis"
    mkdir -p "$DATA_DIR/storage"

    # Set permissions (important for PostgreSQL)
    chmod 755 "$DATA_DIR"
    chmod 700 "$DATA_DIR/postgres"  # PostgreSQL requires strict permissions
    chmod 755 "$DATA_DIR/redis"
    chmod 755 "$DATA_DIR/storage"

    log_success "Data directories created:"
    echo "  - $DATA_DIR/postgres (PostgreSQL data)"
    echo "  - $DATA_DIR/redis (Redis persistence)"
    echo "  - $DATA_DIR/storage (Rails Active Storage)"
}

# Start services
start_services() {
    log_info "Starting Sure with persistent storage..."

    cd "$PROJECT_DIR"

    # Export DATA_DIR for docker-compose
    export DATA_DIR

    # Build and start
    docker compose -f "$COMPOSE_FILE" up -d --build

    log_success "Services started!"
    echo ""
    echo "Application: http://localhost:${PORT:-3000}"
    echo ""
    echo "To view logs: ./scripts/persistent-setup.sh logs"
    echo "To stop:      ./scripts/persistent-setup.sh stop"
}

# Stop services
stop_services() {
    log_info "Stopping Sure services..."

    cd "$PROJECT_DIR"
    export DATA_DIR

    docker compose -f "$COMPOSE_FILE" down

    log_success "Services stopped. Your data is preserved in: $DATA_DIR"
}

# View logs
view_logs() {
    cd "$PROJECT_DIR"
    export DATA_DIR

    docker compose -f "$COMPOSE_FILE" logs -f
}

# Check status
check_status() {
    cd "$PROJECT_DIR"
    export DATA_DIR

    echo ""
    log_info "Container Status:"
    docker compose -f "$COMPOSE_FILE" ps

    echo ""
    log_info "Data Directory Status:"
    if [ -d "$DATA_DIR" ]; then
        echo "  Location: $DATA_DIR"
        echo "  PostgreSQL: $(du -sh "$DATA_DIR/postgres" 2>/dev/null | cut -f1 || echo 'empty')"
        echo "  Redis: $(du -sh "$DATA_DIR/redis" 2>/dev/null | cut -f1 || echo 'empty')"
        echo "  Storage: $(du -sh "$DATA_DIR/storage" 2>/dev/null | cut -f1 || echo 'empty')"
    else
        log_warn "Data directory not found at: $DATA_DIR"
    fi
}

# Backup data
backup_data() {
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/sure_backup_$TIMESTAMP.tar.gz"

    log_info "Creating backup..."

    mkdir -p "$BACKUP_DIR"

    # Stop services for consistent backup
    log_info "Stopping services for consistent backup..."
    cd "$PROJECT_DIR"
    export DATA_DIR
    docker compose -f "$COMPOSE_FILE" stop

    # Create backup
    log_info "Compressing data directory..."
    tar -czf "$BACKUP_FILE" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"

    # Restart services
    log_info "Restarting services..."
    docker compose -f "$COMPOSE_FILE" start

    log_success "Backup created: $BACKUP_FILE"
    echo "  Size: $(du -h "$BACKUP_FILE" | cut -f1)"
    echo ""
    echo "To restore: tar -xzf $BACKUP_FILE -C $(dirname "$DATA_DIR")"
}

# Restore from backup
restore_data() {
    BACKUP_FILE="$1"

    if [ -z "$BACKUP_FILE" ]; then
        log_error "Usage: $0 restore <backup_file.tar.gz>"
        exit 1
    fi

    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    log_warn "This will REPLACE your current data with the backup!"
    read -p "Are you sure? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Restore cancelled"
        exit 0
    fi

    # Stop services
    log_info "Stopping services..."
    cd "$PROJECT_DIR"
    export DATA_DIR
    docker compose -f "$COMPOSE_FILE" down

    # Backup current data just in case
    if [ -d "$DATA_DIR" ]; then
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        log_info "Backing up current data to ${DATA_DIR}_pre_restore_$TIMESTAMP"
        mv "$DATA_DIR" "${DATA_DIR}_pre_restore_$TIMESTAMP"
    fi

    # Restore
    log_info "Restoring from backup..."
    tar -xzf "$BACKUP_FILE" -C "$(dirname "$DATA_DIR")"

    # Fix permissions
    chmod 700 "$DATA_DIR/postgres"

    # Restart
    log_info "Starting services..."
    docker compose -f "$COMPOSE_FILE" up -d

    log_success "Restore complete!"
}

# Main
case "${1:-setup}" in
    setup)
        check_docker
        setup_directories
        start_services
        ;;
    start)
        check_docker
        start_services
        ;;
    stop)
        stop_services
        ;;
    logs)
        view_logs
        ;;
    status)
        check_status
        ;;
    backup)
        check_docker
        backup_data
        ;;
    restore)
        check_docker
        restore_data "$2"
        ;;
    *)
        echo "Usage: $0 {setup|start|stop|logs|status|backup|restore <file>}"
        echo ""
        echo "Commands:"
        echo "  setup   - Create directories and start services (default)"
        echo "  start   - Start services"
        echo "  stop    - Stop services (data is preserved)"
        echo "  logs    - View service logs"
        echo "  status  - Check status and data sizes"
        echo "  backup  - Create a backup of all data"
        echo "  restore - Restore from a backup file"
        exit 1
        ;;
esac

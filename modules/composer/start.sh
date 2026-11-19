#!/usr/bin/env bash
set -euo pipefail
trap 'echo -e "${RED}[composer] Error on line $LINENO${NC}"' ERR

# Color definitions
BLUE='\033[0;34m'; BOLD_BLUE='\033[1;34m'
WHITE='\033[0;37m'; GREEN='\033[0;32m'
YELLOW='\033[0;33m'; RED='\033[0;31m'
NC='\033[0m'

header() {
  echo -e "${BLUE}───────────────────────────────────────────────${NC}"
  echo -e "${BOLD_BLUE}[Composer] $1${NC}"
}

COMPOSER_STATUS="${COMPOSER_STATUS:-false}"
COMPOSER_MODULES="${COMPOSER_MODULES:-}"
CACHE_DIR="${COMPOSER_CACHE_DIR:-/home/container/.cache/composer}"
WWW_DIR="${COMPOSER_WWW_DIR:-/home/container/www}"
COMPOSER_JSON="$WWW_DIR/composer.json"
JOB_FILE="/home/container/.prmhosting/composer-job.json"
META_FILE="/home/container/.prmhosting/composer-meta.json"
STATUS_FILE="/home/container/.prmhosting/composer-status.json"

enabled() { [[ "$1" =~ ^(true|1)$ ]]; }

if ! enabled "$COMPOSER_STATUS"; then
  exit 0
fi

mkdir -p "$CACHE_DIR" /home/container/.prmhosting
export COMPOSER_CACHE_DIR="$CACHE_DIR"

NO_DEV_ARGS=()
if [[ -f "$META_FILE" ]] && grep -q '"mode"[[:space:]]*:[[:space:]]*"production"' "$META_FILE"; then
  NO_DEV_ARGS+=(--no-dev)
  echo -e "${WHITE}[Composer] Mode=production (--no-dev)${NC}"
elif [[ -f "$META_FILE" ]] && grep -q '"mode"[[:space:]]*:[[:space:]]*"development"' "$META_FILE"; then
  echo -e "${WHITE}[Composer] Mode=development${NC}"
else
  # Default production-safe
  NO_DEV_ARGS+=(--no-dev)
fi

write_status() {
  local state="$1"
  local action="$2"
  local detail="${3:-}"
  cat > "$STATUS_FILE" <<EOF
{
  "state": "$state",
  "action": "$action",
  "detail": $(php -r 'echo json_encode($argv[1]);' "$detail"),
  "at": $(date +%s)
}
EOF
}

run_job() {
  local action packages
  action="$(php -r '$j=@json_decode(@file_get_contents($argv[1]), true); echo $j["action"]??"";' "$JOB_FILE")"
  packages="$(php -r '$j=@json_decode(@file_get_contents($argv[1]), true); echo isset($j["packages"])&&is_array($j["packages"])?implode(" ",$j["packages"]):"";' "$JOB_FILE")"

  header "Running queued job: $action"
  write_status "running" "$action" "started"

  case "$action" in
    install)
      composer install --working-dir="$WWW_DIR" --no-interaction --ansi "${NO_DEV_ARGS[@]}"
      ;;
    update)
      if [[ -n "$packages" ]]; then
        # shellcheck disable=SC2086
        composer update $packages --working-dir="$WWW_DIR" --no-interaction --ansi "${NO_DEV_ARGS[@]}"
      else
        composer update --working-dir="$WWW_DIR" --no-interaction --ansi "${NO_DEV_ARGS[@]}"
      fi
      ;;
    require)
      if [[ -z "$packages" ]]; then
        echo -e "${RED}[Composer] require job missing packages${NC}"
        write_status "error" "require" "missing packages"
        rm -f "$JOB_FILE"
        return 1
      fi
      # shellcheck disable=SC2086
      composer require $packages --working-dir="$WWW_DIR" --no-interaction --ansi "${NO_DEV_ARGS[@]}"
      ;;
    remove)
      if [[ -z "$packages" ]]; then
        write_status "error" "remove" "missing packages"
        rm -f "$JOB_FILE"
        return 1
      fi
      # shellcheck disable=SC2086
      composer remove $packages --working-dir="$WWW_DIR" --no-interaction --ansi "${NO_DEV_ARGS[@]}"
      ;;
    *)
      echo -e "${YELLOW}[Composer] Unknown job action: $action${NC}"
      write_status "error" "$action" "unknown action"
      rm -f "$JOB_FILE"
      return 1
      ;;
  esac

  write_status "ok" "$action" "completed"
  rm -f "$JOB_FILE"
  header "Composer job complete"
}

if [[ -f "$JOB_FILE" ]]; then
  run_job
  exit 0
fi

header "Installing Composer packages"

if [[ -f "$COMPOSER_JSON" ]]; then
  echo -e "${WHITE}[Composer] composer.json found. Running install...${NC}"
  composer install --working-dir="$WWW_DIR" --no-interaction --ansi "${NO_DEV_ARGS[@]}"
  write_status "ok" "install" "startup install"
  header "Composer install complete"
elif [[ -n "$COMPOSER_MODULES" ]]; then
  echo -e "${WHITE}[Composer] Installing from COMPOSER_MODULES: $COMPOSER_MODULES${NC}"
  # shellcheck disable=SC2086
  composer require $COMPOSER_MODULES --working-dir="$WWW_DIR" --no-interaction --ansi "${NO_DEV_ARGS[@]}"
  write_status "ok" "require" "COMPOSER_MODULES"
  header "Composer module installation complete"
else
  echo -e "${YELLOW}[Composer] No composer.json and no modules specified. Skipping.${NC}"
fi

#!/usr/bin/env bash
set -euo pipefail

# ── Configuration (override via .env or environment variables) ─────────────────
ENV_FILE="$(dirname "${BASH_SOURCE[0]}")/.env"
[[ -f "$ENV_FILE" ]] && set -a && . "$ENV_FILE" && set +a

. "$(dirname "${BASH_SOURCE[0]}")/lib_common.sh"

WORK_DIR="${WORK_DIR:-/volume1/docker/openhab/general}"
OH_DATA_ROOT="${OH_DATA_ROOT:-/volume1/docker/openhab}"

openhab_ip="${OPENHAB_IP:-192.168.11.10}"
openhab_http_port="${OPENHAB_HTTP_PORT:-8080}"
openhab_https_port="${OPENHAB_HTTPS_PORT:-8443}"

oh_user_id="${OH_USER_ID:-9999}"
oh_group_id="${OH_GROUP_ID:-999}"

TZ="${TZ:-Europe/Berlin}"

cd "$WORK_DIR"

container_file="./active_container"
backup_base="${WORK_DIR}/../backups"

# ── Pre-flight checks ──────────────────────────────────────────────────────────
preflight_errors=()

for cmd in docker jq zip rsync curl; do
    command -v "$cmd" &>/dev/null || preflight_errors+=("Required command not found: $cmd")
done

docker ps &>/dev/null || preflight_errors+=("Docker daemon is not reachable")

[[ -f "$container_file" ]] || preflight_errors+=("State file not found: $container_file")

if [[ ${#preflight_errors[@]} -gt 0 ]]; then
    for err in "${preflight_errors[@]}"; do
        echo "ERROR: $err" >&2
    done
    exit 1
fi

timestamp=$(date +%Y%m%d_%H%M%S)

current_god=$(cat "$container_file")
current_container="openhab-$current_god"

target_tag="latest"

if docker ps --format '{{.Names}}' | grep -q "^${current_container}$"; then
    echo "Container $current_container is running"
else
    echo "Container $current_container is NOT running"
	send_telegram "Container $current_container was found to be not running. Major problem suspected."
    exit 1
fi



if [[ "$current_god" == "hera" ]]; then
    dormant_god="zeus"
else
    dormant_god="hera"
fi
dormant_name="openhab-$dormant_god"


docker pull "openhab/openhab:$target_tag"

current_version=$(docker inspect "$current_container" | jq -r '.[0].Config.Labels["org.opencontainers.image.version"] // "unknown"')
target_version=$(docker image inspect openhab/openhab:$target_tag | jq -r '.[0].Config.Labels["org.opencontainers.image.version"] // "unknown"')
if [[ "$current_version" == "unknown" || "$target_version" == "unknown" ]]; then
  logger -t openhab-updater "WARN: version labels unknown (current=$current_version, latest=$target_version); skipping upgrade compare"
  target_version="$current_version"
fi



echo "starting backup"
docker stop --time 30 "$current_container"
mkdir -p "$backup_base"
zip -r "${backup_base}/openhab_${timestamp}_${current_god}.zip" "${OH_DATA_ROOT}/${current_god}" \
  -x "*/userdata/cache/*" -x "*/userdata/tmp/*"


if [[ "$(printf '%s\n' "$current_version" "$target_version" | sort -V | tail -n1)" != "$current_version" ]]; then
	#UPDATE
    echo "Update available, preparing for upgrade"
	logger -t openhab-updater "Update available: current=$current_version latest=$target_version"
	send_telegram "Update available: current=$current_version latest=$target_version. Performing update."
	echo "Syncing ../$current_god -> ../$dormant_god ..."
	if ! rsync -aHAX --delete --numeric-ids --info=stats2 \
	  "${OH_DATA_ROOT}/${current_god}/" "${OH_DATA_ROOT}/${dormant_god}/"; then
	  logger -t openhab-updater "ERROR: rsync failed; aborting upgrade"
	  send_telegram "rsync failed when preparing $dormant_god; aborting upgrade."
	  docker start "$current_container" >/dev/null
	  exit 1
	fi

	
	if docker ps -a --format '{{.Names}}' | grep -q "^${dormant_name}$"; then
		echo "Removing existing $dormant_name ..."
		docker rm -f "$dormant_name"
	fi
	
	if ! docker run -d \
	  --name "openhab-$dormant_god" \
	  --network macvlan --ip "$openhab_ip" \
	  --restart=always \
	  -e USER_ID="$oh_user_id"	  \
	  -e GROUP_ID="$oh_group_id" \
	  -e TZ="$TZ" \
	  -e OPENHAB_HTTP_PORT="$openhab_http_port" \
	  -e OPENHAB_HTTPS_PORT="$openhab_https_port" \
	  -v "${OH_DATA_ROOT}/$dormant_god/addons:/openhab/addons" \
	  -v "${OH_DATA_ROOT}/$dormant_god/conf:/openhab/conf" \
	  -v "${OH_DATA_ROOT}/$dormant_god/userdata:/openhab/userdata" \
	  "openhab/openhab:$target_tag"
	then
	  logger -t openhab-updater "ERROR: docker run failed for $dormant_name"
	  send_telegram "docker run failed for $dormant_name"
	  # Rollback:
	  if ! docker container stop -t 60 "$dormant_name" 2>/dev/null; then
	    logger -t openhab-updater "WARNING: could not stop $dormant_name (may already be stopped)"
	  fi
	  sleep 90
	  if ! docker start "$current_container"; then
	    logger -t openhab-updater "ERROR: Failed to restart $current_container during rollback"
	    send_telegram "CRITICAL: Failed to restart $current_container during rollback!"
	    exit 1
	  fi
	  sleep 300

	  if docker ps --format '{{.Names}}' | grep -q "^${current_container}$"; then
				if ./check_oh.sh "$openhab_ip" "$openhab_http_port"; then
					logger -t openhab-updater "Rollback successful: now active=$current_god"
					send_telegram "Rollback successful: now active=$current_god"
					echo "Verified: $current_god is running"
				else
					logger -t openhab-updater "Rollback failed: no OH running"
					send_telegram "Rollback failed: no OH running"
					echo "Rollback failed: no OH running"
					exit 1
				fi
			else
				echo "ERROR: $current_god is not running after start"
				send_telegram "failed to start $current_god after backup!"
				exit 1
			fi
	  
	  exit 1
	fi

	
	sleep 300
	if ./check_oh.sh "$openhab_ip" "$openhab_http_port"; then
	  # Atomic write: write to temp, verify, then rename
	  if ! printf '%s\n' "$dormant_god" > "${container_file}.tmp"; then
	    logger -t openhab-updater "ERROR: Failed to write state file"
	    send_telegram "CRITICAL: Failed to write state file after upgrade!"
	    exit 1
	  fi
	  mv "${container_file}.tmp" "$container_file"
	  logger -t openhab-updater "Upgrade successful: active=$dormant_god (was $current_god)"
	  send_telegram "Upgrade successful: now active=$dormant_god (was $current_god)"
	else
		logger -t openhab-updater "Upgrade failed during health-check. Restarting $current_god with version $current_version."
		send_telegram "Upgrade failed during health-check. Restarting $current_god with version $current_version."
		if docker start "$current_container" >/dev/null; then
			echo "Container $current_container started successfully"
			if docker ps --format '{{.Names}}' | grep -q "^${current_container}$"; then
				if ./check_oh.sh "$openhab_ip" "$openhab_http_port"; then
					logger -t openhab-updater "Rollback successful: now active=$current_god"
					send_telegram "Rollback successful: now active=$current_god"
					echo "Verified: $current_god is running"
				else
					logger -t openhab-updater "Rollback failed: no OH running"
					send_telegram "Rollback failed: no OH running"
					echo "Rollback failed: no OH running"
					exit 1
				fi
			else
				echo "ERROR: $current_god is not running after start"
				send_telegram "failed to start $current_god after backup!"
				exit 1
			fi
		else
			echo "ERROR: Failed to start $current_god"
			send_telegram "failed to start $current_god after backup!"
			exit 1
		fi 
	fi
	
	
	
else
	#NO UPDATE
    echo "Running current version"
	logger -t openhab-updater "No update available: current=$current_version latest=$target_version"
	echo "Restarting container"
	
	if docker start "$current_container" >/dev/null; then
		echo "Container $current_container started successfully"
		# Optional: verify it's running in docker ps
		if docker ps --format '{{.Names}}' | grep -q "^${current_container}$"; then
			echo "Verified: $current_god is running"
		else
			echo "ERROR: $current_god is not running after start"
			send_telegram "failed to start $current_god after backup!"
			exit 1
		fi
	else
		echo "ERROR: Failed to start $current_god"
		send_telegram "failed to start $current_god after backup!"
		exit 1
	fi
fi

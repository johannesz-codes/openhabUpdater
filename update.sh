#!/usr/bin/env bash
set -euo pipefail

cd /volume1/docker/openhab/general



ENV_FILE="./.env"
[[ -f "$ENV_FILE" ]] && set -a && . "$ENV_FILE" && set +a

. ./lib_common.sh


container_file="./active_container"
backup_dir="../"

openhab_ip="192.168.11.10"
openhab_http_port="8080"
openhab_https_port="8443"

oh_user_id="9999"
oh_group_id="999"


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

if docker ps -a --format '{{.Names}}' | grep -q "^${dormant_name}$"; then
    docker update --restart=no "$dormant_name" 2>/dev/null || true
fi

docker pull "openhab/openhab:$target_tag"

current_version=$(docker inspect "$current_container" | jq -r '.[0].Config.Labels["org.opencontainers.image.version"] // "unknown"')
target_version=$(docker image inspect openhab/openhab:$target_tag | jq -r '.[0].Config.Labels["org.opencontainers.image.version"] // "unknown"')
if [[ "$current_version" == "unknown" || "$target_version" == "unknown" ]]; then
  logger -t openhab-updater "WARN: version labels unknown (current=$current_version, latest=$target_version); skipping upgrade compare"
  target_version="$current_version"
fi



echo "starting backup"
docker stop --time 30 "$current_container"
zip -r "../backups/openhab_${timestamp}_${current_god}.zip" "$backup_dir/$current_god" \
  -x "*/userdata/cache/*" -x "*/userdata/tmp/*"


if [[ "$(printf '%s\n' "$current_version" "$target_version" | sort -V | tail -n1)" != "$current_version" ]]; then
	#UPDATE
    echo "Update available, preparing for upgrade"
	logger -t openhab-updater "Update available: current=$current_version latest=$target_version"
	send_telegram "Update available: current=$current_version latest=$target_version. Performing update."
	echo "Syncing ../$current_god -> ../$dormant_god ..."
	rsync -aHAX --delete --numeric-ids --info=stats2 \
	"../${current_god}/" "../${dormant_god}/"

	
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
	  -e TZ=Europe/Berlin \
	  -e OPENHAB_HTTP_PORT="$openhab_http_port" \
	  -e OPENHAB_HTTPS_PORT="$openhab_https_port" \
	  -v "/volume1/docker/openhab/$dormant_god/addons:/openhab/addons" \
	  -v "/volume1/docker/openhab/$dormant_god/conf:/openhab/conf" \
	  -v "/volume1/docker/openhab/$dormant_god/userdata:/openhab/userdata" \
	  "openhab/openhab:$target_tag"
	then
	  logger -t openhab-updater "ERROR: docker run failed for $dormant_name"
	  send_telegram "docker run failed for $dormant_name"
	  # Rollback:
	  docker container stop -t 60 "$dormant_name" 2>/dev/null || true
	  sleep 90
	  docker start "$current_container" || true
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
	  echo "$dormant_god" > "$container_file"
	  logger -t openhab-updater "Upgrade successful: active=$dormant_god (was $current_god)"
	  send_telegram "Upgrade successful: now active=$dormant_god (was $current_god)"
	  docker update --restart=no "$current_container" 2>/dev/null || true
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
					docker stop "$dormant_name" 2>/dev/null || true
					docker update --restart=no "$dormant_name" 2>/dev/null || true
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

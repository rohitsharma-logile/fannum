#!/bin/bash

set -u

APP_SERVER_IP="$1"
DEPLOYMENT_DIR="$(echo "$2" | base64 -d)"
START_SCRIPT_PATH="$3"
STOP_SCRIPT_PATH="$4"
PRODUCT_MODULE_INPUT="$5"
ACTION="$6"
MAX_SLEEP_TIME="${7:-480}"
INTERVAL="${8:-5}"

case "$PRODUCT_MODULE_INPUT" in
    LP)  
        PRODUCT_MODULE="elm"
        APP_SERVER_PORT=9080
        SERVER_ID="sow1"
        ;;
    WFM) 
        PRODUCT_MODULE="portal" 
        APP_SERVER_PORT=9081
        SERVER_ID="sow2"
        ;;
    *)   echo "Invalid module: $PRODUCT_MODULE_INPUT"; exit 1 ;;
esac

[[ ! -d "$DEPLOYMENT_DIR" ]] && echo "Error: Invalid deployment dir: $DEPLOYMENT_DIR" && exit 1
[[ ! -f "$START_SCRIPT_PATH" ]] && echo "Error: Invalid script path: $SCRIPT_PATH" && exit 1
[[ ! -f "$STOP_SCRIPT_PATH" ]] && echo "Error: Invalid script path: $SCRIPT_PATH" && exit 1

ERR_FILE="${DEPLOYMENT_DIR}/elm.ear.failed"
DEPLOYED_FILE="${DEPLOYMENT_DIR}/elm.ear.deployed"

get_status() {
    echo $(curl -s -o /dev/null -w "%{http_code}" "http://$APP_SERVER_IP:$APP_SERVER_PORT/${PRODUCT_MODULE,,}")
}

get_cpu_usage() {
    local cpu=$(top -bn1 | awk -F'[, ]+' '/Cpu\(s\)/ {print $2+$4}')
    cpu=${cpu%.*}
    echo "$cpu"
}

collect_diagnostics() {
    local CPU_USAGE=$(get_cpu_usage)
    if [[ $CPU_USAGE > 80 ]]; then
        echo "CPU Usage is above threshold of 80: $CPU_USAGE. Skipping log creation."
        echo "ZIP_STATUS:SKIPPED"
        return
    fi
    
    local TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    local ZIP_NAME="j-logs.zip"

    rm -f "$ZIP_NAME"

    local PID=$(pgrep -f "java.*${SERVER_ID}" | head -1)

    if [[ -z "$PID" ]]; then
        echo "PID not found for $SERVER_ID, skipping diagnostics."
        return
    fi

    echo "Creating log files"
    cp "gc-${SERVER_ID}.log" "gc-${SERVER_ID}-${TIMESTAMP}.log" 2>/dev/null || true
    sudo jstack -F "$PID" > "jenkins-jstack-${SERVER_ID}-${TIMESTAMP}.log" 2>/dev/null || true
    sudo jmap -histo "$PID" > "jmap-${SERVER_ID}-${TIMESTAMP}.log" 2>/dev/null || true

    echo "Zipping log files"
    zip "$ZIP_NAME" "gc-${SERVER_ID}-${TIMESTAMP}.log" \
                    "jenkins-jstack-${SERVER_ID}-${TIMESTAMP}.log" \
                    "jmap-${SERVER_ID}-${TIMESTAMP}.log" 2>/dev/null || true

    if [[ -f "$ZIP_NAME" ]]; then
        local SIZE=$(stat -c%s "$ZIP_NAME" 2>/dev/null || stat -f%z "$ZIP_NAME")
        echo "Total size of final zip: $SIZE Bytes"
        
        if (( SIZE > 23068672 )); then
             rm "$ZIP_NAME"
             echo "Deleting zip because it exceeds threshold of 23068672 Bytes: $SIZE Bytes"
             echo "ZIP_STATUS:DELETED"
        fi
    fi
}

stop_app() {
    if [[ "$ACTION" == "STOP" ]]; then
        collect_diagnostics
    fi

    sudo bash -c "$STOP_SCRIPT_PATH" || true

    if [[ "$ACTION" == "STOP" ]]; then
        local STATUS=$(get_status)
        if [[ "$STATUS" == "503" || "$STATUS" == "000" ]]; then
            echo "DEPLOY_STATUS:SUCCESS"
        else
            echo "DEPLOY_STATUS:ERROR (Status: $STATUS)"
        fi
    fi
}

start_app() {
    # If currently running, stop it first
    if [[ "$(get_status)" == "302" ]]; then
        echo "App is already running. Killing it first."
        stop_app
        echo "Sleeping for 5 seconds"
        sleep 5
    fi

    echo "Executing start script at $START_SCRIPT_PATH"
    sudo bash -c "$START_SCRIPT_PATH" || { echo "DEPLOY_STATUS:START_FAILED"; exit 1; }

    echo "Sleeping for 5 seconds"
    sleep 5
    
    local elapsed=0

    echo "Checking for status in $DEPLOYMENT_DIR folder"
    while (( elapsed < MAX_SLEEP_TIME )); do
        if [[ -f "$ERR_FILE" ]]; then
            echo "Build failed: Found $ERR_FILE that represents failure"
            echo "DEPLOY_STATUS:ERROR"
            exit 1
        elif [[ -f "$DEPLOYED_FILE" ]] && [[ "$(get_status)" == "302" ]]; then
            echo "DEPLOY_STATUS:SUCCESS"
            exit 0
        else
            sleep "$INTERVAL"
            (( elapsed += INTERVAL ))
        fi
    done

    echo "DEPLOY_STATUS:TIMEOUT"
    exit 1
}

case "$ACTION" in
    START) start_app ;;
    STOP)  stop_app ;;
    *)     echo "Invalid action: $ACTION"; exit 1 ;;
esac

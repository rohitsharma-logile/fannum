#!/bin/bash

APP_SERVER_IP="$1"
DEPLOYMENT_DIR="$(echo $2 | base64 -d)"
SCRIPT_PATH="$3"
PRODUCT_MODULE="$4"
ACTION="$5"
MAX_SLEEP_TIME="${6:-480}"
INTERVAL="${7:-5}"

APP_SERVER_PORT=0

case "$PRODUCT_MODULE" in
    lp)  PRODUCT_MODULE="elm" ;;
    wfm) PRODUCT_MODULE="portal" ;;
    *)   echo "Invalid module"; exit 1 ;;
esac

[[ ! -d "$DEPLOYMENT_DIR" ]] && echo "Invalid deployment dir" && exit 1
[[ ! -f "$SCRIPT_PATH" ]] && echo "Invalid script path" && exit 1

[[ "$PRODUCT_MODULE" == "elm" ]] && APP_SERVER_PORT=9080 || APP_SERVER_PORT=9081

case "$ACTION" in
    start|stop) ;;
    *) echo "Invalid action"; exit 1 ;;
esac

ERR_FILE="${DEPLOYMENT_DIR}/elm.ear.failed"
DEPLOYED_FILE="${DEPLOYMENT_DIR}/elm.ear.deployed"
IS_DEPLOYING_FILE="${DEPLOYMENT_DIR}/elm.ear.isdeploying"

get_status() {
    curl -s -o /dev/null -w "%{http_code}" "http://$APP_SERVER_IP:$APP_SERVER_PORT/$PRODUCT_MODULE"
}

stop_app() {
    local TIMESTAMP=`date +%Y%m%d-%H%M%S`
    rm -rf j-logs.zip

    if [[ "$PRODUCT_MODULE" == "elm" ]]; then
        local PID=`ps -eaf | grep java | grep sow1 | awk '{print $2}'`
        echo ps -eaf | grep java | grep sow1
        cp gc-sow1.log gc-sow1-${TIMESTAMP}.log
        sudo jstack -F $PID > jenkins-jstack-sow1-${TIMESTAMP}.log
        sudo jmap -histo $PID > jmap-sow1-${TIMESTAMP}.log

        zip -r j-logs.zip gc-sow1-${TIMESTAMP}.log jenkins-jstack-sow1-${TIMESTAMP}.log jmap-sow1-${TIMESTAMP}.log
    else
        local PID=`ps -eaf | grep java | grep sow2 | awk '{print $2}'`
        cp gc-sow2.log gc-sow2-${TIMESTAMP}.log
        sudo jstack -F $PID > jenkins-jstack-sow2-${TIMESTAMP}.log
        sudo jmap -histo $PID > jmap-sow2-${TIMESTAMP}.log

        zip -r j-logs.zip gc-sow2-${TIMESTAMP}.log jenkins-jstack-sow2-${TIMESTAMP}.log jmap-sow2-${TIMESTAMP}.log
    fi

    sudo bash -c "$SCRIPT_PATH" || true

    STATUS=$(get_status)
    if [[ "$STATUS" == "503" || "$STATUS" == "000" ]]; then
        echo DEPLOY_STATUS:SUCCESS
    else
        echo DEPLOY_STATUS:ERROR
    fi
    # Delete if zip is greater than 22MB
    [ $(du -k j-logs.zip | cut -f1) -gt $((22 * 1024)) ] && {
        rm j-logs.zip
        echo "ZIP_STATUS:DELETED"
    }
}

start_app() {
    # App already running → stop first
    if [[ "$(get_status)" == "302" ]]; then
        stop_app || exit 1
    fi

    sleep 10

    sudo "$SCRIPT_PATH" || { echo DEPLOY_STATUS:START_FAILED; exit 1; }

    elapsed=0
    while (( elapsed < MAX_SLEEP_TIME )); do

        if [[ -f "$ERR_FILE" ]]; then
            echo DEPLOY_STATUS:ERROR
            exit 1

        elif [[ -f "$DEPLOYED_FILE" ]] && [[ "$(get_status)" == "302" ]]; then
            echo DEPLOY_STATUS:SUCCESS
            exit 0

        else
            # wait and increment always — allow deployment system to create files
            sleep "$INTERVAL"
            (( elapsed += INTERVAL ))
        fi
    done

    echo DEPLOY_STATUS:TIMEOUT
    exit 1
}

if [[ "$ACTION" == "start" ]]; then
    start_app
    exit 0
fi

if [[ "$ACTION" == "stop" ]]; then
    stop_app
    exit 0
fi

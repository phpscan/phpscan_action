#!/bin/bash

#default variables
WAIT_COMPLETE=false
DEBUG=false

function failedSignal() {
  ENDPOINT_FAILED="https://api.phpscan.com/api/check/ci_failed"
  RESPONSE_FAILED=$(curl --silent -H 'content-type: application/json' -H "Authorization: Bearer $PHPSCAN_AUTH_TOKEN" -G $ENDPOINT_FAILED)
}

#function successSignal() {
#  ENDPOINT_SUCCESS="https://api.phpscan.com/api/check/ci_success/$1"
#  CMD="curl --silent --location "$ENDPOINT_SUCCESS" --header "Authorization: Bearer $PHP_SCAN_AUTH_TOKEN"
#  RESPONSE_SUCCESS=$(curl --silent --location "$ENDPOINT_SUCCESS" --header "Authorization: Bearer $PHP_SCAN_AUTH_TOKEN")
#}

function successSignal() {
  ENDPOINT_SUCCESS="https://api.phpscan.com/api/check/ci_success/$1"
  CMD="curl --silent --location \"$ENDPOINT_SUCCESS\" --header \"Authorization: Bearer $PHPSCAN_AUTH_TOKEN\""
  echo "ci_success"
  echo $CMD
  eval "$CMD"
}

while getopts ":w:d:" o; do
  case "${o}" in
  w)
    echo "Find 'w' option - waiting for the completion of the analysis"
    WAIT_COMPLETE=true
    ;;

  d)
    echo "Find 'd' option - enabled debug mode"
    DEBUG=true
    ;;
  esac
done

PHPSCAN_PROJECT_NAME=$INPUT_PROJECT_NAME
if [ -z "$PHPSCAN_PROJECT_NAME" ] && [ "$PROJECT_NAME" ]; then
  PHPSCAN_PROJECT_NAME=$PROJECT_NAME
fi

if $DEBUG; then
  echo "Use auth token: $PHPSCAN_AUTH_TOKEN"
fi

ENDPOINT="https://api.phpscan.com/api/projects"

if [ -z "$PHPSCAN_PROJECT_NAME" ]; then
  PHPSCAN_PROJECT_NAME=$GITHUB_REPOSITORY
  echo "INPUT_PROJECT_NAME is empty. Use default value: '$PHPSCAN_PROJECT_NAME'"
fi

#1. Prepare source
REQUIRE_COMPOSER=false
if [ -f "./composer.json" ]; then
  REQUIRE_COMPOSER=true
fi

if $REQUIRE_COMPOSER; then
  #install php
  apt-get update && apt-get install -y --no-install-recommends php-cli php-zip

  #install composer
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer

  echo "Install composer dependencies"
  composer install --no-dev --ignore-platform-reqs --no-interaction --no-scripts
fi

#2. Prepare archive
echo "Create sources archive"
zip -r /tmp/sources.zip $GITHUB_WORKSPACE/ -i '*.php'
if [ $? -ne 0 ]; then
  failedSignal
  echo "Failed to get archive with source code." >&2
  exit 1
fi

# create project.
PROJECT_POST_DATA="{\"name\":\"$PHPSCAN_PROJECT_NAME\",\"type\":2}"
if $DEBUG; then
  echo "Try create project: $PROJECT_POST_DATA"
fi

PROJECT_DATA=$(curl --silent -H 'content-type: application/json' -H "Authorization: Bearer $PHPSCAN_AUTH_TOKEN" -X POST $ENDPOINT/get_uuid --data-raw "$PROJECT_POST_DATA")

if $DEBUG; then
  echo "API response PROJECT_DATA: $PROJECT_DATA"
fi

if [ $? -ne 0 ]; then
  failedSignal
  echo "Failed to create project. Check the API key (environment variable PHPSCAN_AUTH_TOKEN)" >&2
  exit 1
fi

#take uuid from answer
PROJECT_UUID=$(echo $PROJECT_DATA | jq -r '.uuid')
if [ -z "$PROJECT_UUID" ]; then
  failedSignal
  echo "Failed to get project uuid" >&2
  exit 1
fi

if $DEBUG; then
  echo "PROJECT_DATA UUID: $PROJECT_UUID"
fi

echo "Getting a secure URL to upload the archive"
UPLOAD_DATA=$(curl --silent -H "Authorization: Bearer $PHPSCAN_AUTH_TOKEN" $ENDPOINT/upload_url/$PROJECT_UUID)
if [ $? -ne 0 ]; then
  failedSignal
  echo "Error while getting URL for secure archive upload." >&2
  exit 1
fi

if $DEBUG; then
  echo "API response upload url: $UPLOAD_DATA"
fi

#take upload url
UPLOAD_URL=$(echo $UPLOAD_DATA | jq -r '.url')
UPLOAD_UUID=$(echo $UPLOAD_DATA | jq -r '.upload_uuid')
if [ -z "$UPLOAD_URL" ]; then
  failedSignal
  echo "Failed to get upload URL. Check the API key (environment variable PHPSCAN_AUTH_TOKEN)." >&2
  exit 1
fi

if $DEBUG; then
  echo "UPLOAD_URL: $UPLOAD_URL"
  echo "UPLOAD_UUID: $UPLOAD_UUID"
fi

echo "Upload an archive to the server"
curl --silent $UPLOAD_URL --upload-file /tmp/sources.zip
if [ $? -ne 0 ]; then
  failedSignal
  echo "Failed to upload archive to S3 storage for further processing." >&2
  exit 1
fi

echo "Running source code analysis"
SECURITY_CHECK_DATA=$(curl --silent -H "Authorization: Bearer $PHPSCAN_AUTH_TOKEN" $ENDPOINT/run/$UPLOAD_UUID/s3)
if [ $? -ne 0 ]; then
  failedSignal
  echo "Failed to run check. Contact technical support https://phpscan.com/" >&2
  exit 1
fi

if $DEBUG; then
  echo "API response start security check: $SECURITY_CHECK_DATA"
fi

SECURITY_CHECK_UUID=$(echo $SECURITY_CHECK_DATA | jq -r '.uuid')
if [ -z "$SECURITY_CHECK_UUID" ]; then
  failedSignal
  echo "Failed to run check. Contact technical support https://phpscan.com/" >&2
  exit 1
fi

if $DEBUG; then
  echo "Security check UUID: $SECURITY_CHECK_UUID"
fi

successSignal $PROJECT_UUID

STATUS_CREATED=1
STATUS_ON_PROCESS=2
STATUS_SUCCESS=3
STATUS_FAIL=4
STATUS_REPORT_GENERATE=5

SCAN_IS_FINISH=false

echo -n "Scan in processing "

for ((i = 1; i <= 10; i++)); do
  SCAN_DATA=$(curl --silent -H "Authorization: Bearer $PHPSCAN_AUTH_TOKEN" $ENDPOINT/$PROJECT_UUID/check)
  SCAN_PERCENT=$(echo $SCAN_DATA | jq -r '.data[0].scannedPercent')
  STAT_CODE_LINES=$(echo $SCAN_DATA | jq -r '.data[0].stats.codeLines')
  PROJECT_STATUS=$(echo $SCAN_DATA | jq -r '.project.last_security_check.status')

  if $SCAN_IS_FINISH; then
    break
  fi

  if [ $PROJECT_STATUS -ne $STATUS_CREATED ] && [ $PROJECT_STATUS -ne $STATUS_ON_PROCESS ]; then
    if [ $PROJECT_STATUS -eq $STATUS_REPORT_GENERATE ]; then
      echo " "
      echo "Scan is finished. We are waiting for the completion of the report generation."
      sleep 5
    elif [ $PROJECT_STATUS -eq $STATUS_SUCCESS ]; then
      SCAN_IS_FINISH=true
      sleep 5
    else
      echo " "
      echo "Scan is finished failed. (status $PROJECT_STATUS)"
      break
    fi
  fi

  if $WAIT_COMPLETE; then
    i=1
  fi

  if [ $PROJECT_STATUS -eq $STATUS_CREATED ] || [ $PROJECT_STATUS -eq $STATUS_ON_PROCESS ]; then
    echo -n "."
  fi

  sleep 1
done

if $DEBUG; then
  echo "API response scan check status: $SCAN_DATA"
fi

if [ $PROJECT_STATUS -eq $STATUS_FAIL ]; then
  echo "Code analysis failed. Contact technical support https://phpscan.com/" >&2
  exit 0
fi

STAT_CODE_LINES=$(echo $SCAN_DATA | jq -r '.data[0].stats.codeLines')
STAT_INJECTIONS=$(echo $SCAN_DATA | jq -r '.data[0].stats.injectionsFound')
STAT_SCANNED_FILES=$(echo $SCAN_DATA | jq -r '.data[0].stats.scannedFiles')
VIEW_URL="https://phpscan.com/personal/projects/$PROJECT_UUID/$SECURITY_CHECK_UUID"
echo " "
echo " "

if [ $SCAN_PERCENT -eq 100 ]; then
  echo "SUMMARY:"
  echo "Code lines: $STAT_CODE_LINES"
  echo "Injections found: $STAT_INJECTIONS"
  echo "Scanned files: $STAT_SCANNED_FILES"
  echo "For a detailed report visit URL: $VIEW_URL"
else
  echo "Code analysis is still ongoing. It may take several minutes."
  echo "For a detailed report visit URL: $VIEW_URL"
fi

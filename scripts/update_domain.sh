#!/bin/bash

# Your NameSilo API key
# Generate at: https://www.namesilo.com/account/api-manager
API_KEY="YOUR-API-KEY"

# Your domain name
DOMAIN="example.com"

# Fetch current public IP
IP=$(curl -s https://api.ipify.org)

if [[ -z "$IP" ]]; then
  echo "Error: Unable to retrieve public IP address."
  exit 1
fi

echo "Current public IP is: $IP"

# Fetch DNS records once
RECORDS_XML=$(curl -s "https://www.namesilo.com/api/dnsListRecords?version=1&type=xml&key=${API_KEY}&domain=${DOMAIN}")

if [[ -z "$RECORDS_XML" ]]; then
  echo "Error: Failed to fetch DNS records for domain $DOMAIN"
  exit 1
fi

# Update each subdomain
for SUBDOMAIN in "@" "www" "matrix"; do
  echo "Checking subdomain: $SUBDOMAIN"

  RECORD_INFO=$(echo "$RECORDS_XML" | awk -v search_host="$SUBDOMAIN" '
    BEGIN { RS="<resource_record>"; FS="\n" }
    /<type>A<\/type>/ {
      host_content = ""
      if (match($0, /<host>([^<]*)<\/host>/, arr_host)) {
        host_content = arr_host[1]
      }

      if (host_content == search_host) {
        match($0, /<record_id>([^<]+)<\/record_id>/, arr_id)
        match($0, /<value>([^<]+)<\/value>/, arr_val)
        print arr_id[1], arr_val[1]
        exit
      }
    }
  ' | head -1)

  RECORD_ID=$(echo "$RECORD_INFO" | awk '{print $1}')
  CURRENT_RECORDED_IP=$(echo "$RECORD_INFO" | awk '{print $2}')

  if [[ -z "$RECORD_ID" ]]; then
    echo "Warning: No A record found for subdomain '$SUBDOMAIN'. Skipping."
    continue
  fi

  if [[ "$IP" == "$CURRENT_RECORDED_IP" ]]; then
    echo "Info: '$SUBDOMAIN.$DOMAIN' already set to $IP."
  else
    RESPONSE=$(curl -s "https://www.namesilo.com/api/dnsUpdateRecord?version=1&type=xml&key=${API_KEY}&domain=${DOMAIN}&rrid=${RECORD_ID}&rrhost=${SUBDOMAIN}&rrvalue=${IP}&rrttl=3600")

    if echo "$RESPONSE" | grep -q "<code>300</code>"; then
      echo "Success: '$SUBDOMAIN.$DOMAIN' updated from $CURRENT_RECORDED_IP to $IP."
    else
      CODE=$(echo "$RESPONSE" | grep -oP "(?<=<code>)[0-9]+(?=</code>)")
      DETAIL=$(echo "$RESPONSE" | grep -oP "(?<=<detail>)[^<]+(?=</detail>)")
      echo "Error: Code $CODE - $DETAIL"
    fi
  fi
done

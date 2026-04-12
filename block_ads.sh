#!/bin/bash

API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_TOTAL_ENTRIES=295000 
MAX_RETRIES=10

function error() { echo "Error: $1"; exit 1; }

echo "Downloading optimized filters..."
curl -sSfL https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/pro.plus.txt > source.txt
curl -sSfL https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/native.apple.txt >> source.txt
curl -sSfL https://raw.githubusercontent.com/bigdargon/hostsVN/master/option/domain.txt >> source.txt

cat <<EOT >> source.txt
ocsp.apple.com
ppq.apple.com
iadsdk.apple.com
EOT

echo "Processing and cleaning..."
# Fix lỗi Broken pipe bằng cách gom sort vào một bước riêng
grep -vE '^\s*(#|$|!)' source.txt | sed 's/0.0.0.0 //g; s/127.0.0.1 //g' > unsorted.txt
sort -u unsorted.txt | head -n $MAX_TOTAL_ENTRIES > domain_list.txt

split -l ${MAX_LIST_SIZE} domain_list.txt domain_list.txt.

echo "Fetching Cloudflare lists..."
current_lists=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json")

used_list_ids=($(echo "${current_lists}" | jq -r --arg PREFIX "$PREFIX" '.result[] | select(.name | contains($PREFIX)) | .id'))

list_counter=1
for file in domain_list.txt.*; do
    formatted_counter=$(printf "%03d" "$list_counter")
    list_name="$PREFIX - $formatted_counter"
    items_json=$(jq -R -s 'split("\n") | map(select(length > 0) | { "value": . })' "$file")

    if [ $list_counter -le ${#used_list_ids[@]} ]; then
        list_id=${used_list_ids[$((list_counter-1))]}
        echo "Syncing List $formatted_counter..."
        
        old_items=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}/items?limit=1000" \
            -H "Authorization: Bearer ${API_TOKEN}" | jq '.result | map({value: .value})')
        
        # FIX TẠI ĐÂY: Dùng pipe để đẩy data trực tiếp vào curl, né lỗi "Argument list too long"
        jq -n --argjson append "$items_json" --argjson remove "$old_items" '{"append": $append, "remove": $remove}' | \
        curl -s -X PATCH "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data-binary @- > /dev/null
    else
        echo "Creating List $formatted_counter..."
        jq -n --arg name "$list_name" --argjson items "$items_json" '{"name": $name, "type": "DOMAIN", "items": $items}' | \
        curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
            -H "Authorization: Bearer ${API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data-binary @- > /dev/null
    fi
    list_counter=$((list_counter + 1))
done

# Rule update
conditions=""
for id in "${used_list_ids[@]}"; do
    [ -n "$conditions" ] && conditions="$conditions or "
    conditions="$conditions any(dns.domains in \$${id})"
done

policy_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
    -H "Authorization: Bearer ${API_TOKEN}" | jq -r --arg PREFIX "$PREFIX" '.result[] | select(.name == $PREFIX) | .id')

if [ -n "$policy_id" ] && [ "$policy_id" != "null" ]; then
    jq -n --arg name "$PREFIX" --arg cond "$conditions" '{"name": $name, "enabled": true, "action": "block", "filters": ["dns"], "traffic": $cond}' | \
    curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/${policy_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data-binary @- > /dev/null
else
    jq -n --arg name "$PREFIX" --arg cond "$conditions" '{"name": $name, "enabled": true, "action": "block", "filters": ["dns"], "traffic": $cond}' | \
    curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data-binary @- > /dev/null
fi

echo "Finish! Ngon lành cành đào rồi ní."

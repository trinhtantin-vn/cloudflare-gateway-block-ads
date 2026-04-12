#!/bin/bash

API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_TOTAL_ENTRIES=295000 
MAX_RETRIES=10

function error() { echo "Error: $1"; exit 1; }

echo "Downloading optimized filters..."
# HaGeZi Multi Pro++ (Nguồn chính cực mạnh)
curl -sSfL https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/pro.plus.txt > source.txt
# HaGeZi Apple OEM (Chặn tracking Apple)
curl -sSfL https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/native.apple.txt >> source.txt
# ABVN (Quảng cáo Việt Nam)
curl -sSfL https://raw.githubusercontent.com/bigdargon/hostsVN/master/option/domain.txt >> source.txt

# Thêm domain chống thu hồi chứng chỉ (ESign/Gbox) cho chắc ăn
cat <<EOT >> source.txt
ocsp.apple.com
ppq.apple.com
iadsdk.apple.com
EOT

echo "Processing and cleaning..."
grep -vE '^\s*(#|$|!)' source.txt | sed 's/0.0.0.0 //g; s/127.0.0.1 //g' | sort -u | head -n $MAX_TOTAL_ENTRIES > domain_list.txt

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
        old_items=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}/items?limit=1000" \
            -H "Authorization: Bearer ${API_TOKEN}" | jq '.result | map({value: .value})')
        payload=$(jq -n --argjson append "$items_json" --argjson remove "$old_items" '{"append": $append, "remove": $remove}')
        curl -s -X PATCH "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$payload" > /dev/null
    else
        payload=$(jq -n --arg name "$list_name" --argjson items "$items_json" '{"name": $name, "type": "DOMAIN", "items": $items}')
        new_list=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
            -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$payload")
        used_list_ids+=($(echo "$new_list" | jq -r '.result.id'))
    fi
    list_counter=$((list_counter + 1))
done

# Cập nhật Firewall Policy
conditions=""
for id in "${used_list_ids[@]}"; do
    [ -n "$conditions" ] && conditions="$conditions or "
    conditions="$conditions any(dns.domains in \$${id})"
done

policy_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
    -H "Authorization: Bearer ${API_TOKEN}" | jq -r --arg PREFIX "$PREFIX" '.result[] | select(.name == $PREFIX) | .id')

json_rule=$(jq -n --arg name "$PREFIX" --arg cond "$conditions" \
    '{"name": $name, "enabled": true, "action": "block", "filters": ["dns"], "traffic": $cond}')

if [ -n "$policy_id" ] && [ "$policy_id" != "null" ]; then
    curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/${policy_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_rule" > /dev/null
else
    curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_rule" > /dev/null
fi

echo "Finish! System is clean and powerful."

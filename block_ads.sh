#!/bin/bash

API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_TOTAL_ENTRIES=150000 # Giảm xuống để lọc domain chất lượng hơn
MAX_RETRIES=10

function error() { echo "Error: $1"; exit 1; }

echo "Downloading Compact & Accurate filters..."
# HaGeZi Multi Normal (Thay Pro++ bằng bản này cho nhẹ và chính xác)
curl -sSfL https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/multi.txt > source.txt
# HaGeZi Apple OEM
curl -sSfL https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/native.apple.txt >> source.txt
# ABVN (Quảng cáo VN)
curl -sSfL https://raw.githubusercontent.com/bigdargon/hostsVN/master/option/domain.txt >> source.txt

# BỔ SUNG GẤP: Danh sách diệt Telemetry Apple để xanh 100% web test
cat <<EOT >> source.txt
ocsp.apple.com
ocsp2.apple.com
ppq.apple.com
crl.apple.com
iadsdk.apple.com
api-adservices.apple.com
books-analytics-events.apple.com
weather-analytics-events.apple.com
notes-analytics-events.apple.com
stocks-analytics-events.apple.com
shazam-events.apple.com
sequoia-metrics.apple.com
tr-events.apple.com
metrics.apple.com
apple.comscoreresearch.com
iad.apple.com
iad-apple.com
EOT

echo "Processing and cleaning..."
grep -vE '^\s*(#|$|!)' source.txt | sed 's/0.0.0.0 //g; s/127.0.0.1 //g' > unsorted.txt
sort -u unsorted.txt | head -n $MAX_TOTAL_ENTRIES > domain_list.txt

split -l ${MAX_LIST_SIZE} domain_list.txt domain_list.txt.

echo "Fetching Cloudflare lists..."
current_lists=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json")

used_list_ids=($(echo "${current_lists}" | jq -r --arg PREFIX "$PREFIX" '.result[] | select(.name | contains($PREFIX)) | .id'))

# Xử lý sync (như bản cũ nhưng dùng data-binary để chống lủng)
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
        jq -n --argjson append "$items_json" --argjson remove "$old_items" '{"append": $append, "remove": $remove}' | \
        curl -s -X PATCH "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data-binary @- > /dev/null
    else
        echo "Creating List $formatted_counter..."
        jq -n --arg name "$list_name" --argjson items "$items_json" '{"name": $name, "type": "DOMAIN", "items": $items}' | \
        curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
            -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data-binary @- > /dev/null
    fi
    list_counter=$((list_counter + 1))
done

# Xóa list thừa nếu ông hạ từ 295 xuống 150
if [ $list_counter -le ${#used_list_ids[@]} ]; then
    for ((i=$((list_counter-1)); i<${#used_list_ids[@]}; i++)); do
        echo "Deleting excess list: ${used_list_ids[$i]}"
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${used_list_ids[$i]}" \
            -H "Authorization: Bearer ${API_TOKEN}" > /dev/null
    done
    # Cập nhật lại mảng IDs sau khi xóa
    used_list_ids=("${used_list_ids[@]:0:$((list_counter-1))}")
fi

# Update Policy
echo "Updating Policy..."
conditions=""
for id in "${used_list_ids[@]}"; do
    [ -n "$conditions" ] && conditions="$conditions or "
    conditions="$conditions any(dns.domains in \$${id})"
done

policy_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
    -H "Authorization: Bearer ${API_TOKEN}" | jq -r --arg PREFIX "$PREFIX" '.result[] | select(.name == $PREFIX) | .id')

jq -n --arg name "$PREFIX" --arg cond "$conditions" '{"name": $name, "enabled": true, "action": "block", "filters": ["dns"], "traffic": $cond}' | \
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/${policy_id}" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data-binary @- > /dev/null

echo "Finish! Gọn nhẹ, sạch sẽ rồi ní."

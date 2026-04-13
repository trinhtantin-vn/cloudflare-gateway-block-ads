#!/bin/bash

API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_TOTAL_ENTRIES=10000 # ABPVN chỉ tầm vài ngàn dòng, để 10k là dư
MAX_RETRIES=10

function error() { echo "Error: $1"; exit 1; }

echo "Downloading ONLY ABPVN (hostsVN) filter..."
# Chỉ lấy nguồn quảng cáo Việt Nam của BigDargon
curl -sSfL https://raw.githubusercontent.com/bigdargon/hostsVN/master/option/domain.txt > source.txt

echo "Processing and cleaning..."
grep -vE '^\s*(#|$|!)' source.txt | sed 's/0.0.0.0 //g; s/127.0.0.1 //g' | sort -u | head -n $MAX_TOTAL_ENTRIES > domain_list.txt

split -l ${MAX_LIST_SIZE} domain_list.txt domain_list.txt.

echo "Fetching Cloudflare lists..."
current_lists=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json")

used_list_ids=($(echo "${current_lists}" | jq -r --arg PREFIX "$PREFIX" '.result[] | select(.name | contains($PREFIX)) | .id'))

# 1. Đồng bộ dữ liệu mới
list_counter=1
for file in domain_list.txt.*; do
    formatted_counter=$(printf "%03d" "$list_counter")
    list_name="$PREFIX - $formatted_counter"
    items_json=$(jq -R -s 'split("\n") | map(select(length > 0) | { "value": . })' "$file")

    if [ $list_counter -le ${#used_list_ids[@]} ]; then
        list_id=${used_list_ids[$((list_counter-1))]}
        echo "Updating List $formatted_counter..."
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

# 2. XÓA SẠCH LIST THỪA (Quan trọng nhất)
# Vì ông đang có gần 300 list, script này sẽ xóa sạch đống list từ 005 đến 295
if [ $list_counter -le ${#used_list_ids[@]} ]; then
    for ((i=$((list_counter-1)); i<${#used_list_ids[@]}; i++)); do
        echo "Deleting excess list: ${used_list_ids[$i]}"
        curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${used_list_ids[$i]}" \
            -H "Authorization: Bearer ${API_TOKEN}" > /dev/null
    done
    used_list_ids=("${used_list_ids[@]:0:$((list_counter-1))}")
fi

# 3. Cập nhật Policy
echo "Updating Firewall Policy..."
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

echo "Finish! Hệ thống đã gọn nhẹ, vào game tẹt ga đi ní."

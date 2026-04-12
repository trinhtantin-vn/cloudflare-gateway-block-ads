#!/bin/bash

# Biến hệ thống
API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_LISTS=100
MAX_RETRIES=10

function error() {
    echo "Error: $1"
    exit 1
}

# 1. Tải list OISD
echo "Downloading OISD list..."
curl -sSfL --retry "$MAX_RETRIES" https://small.oisd.nl/domainswild2 | grep -vE '^\s*(#|$)' > oisd_list.txt || error "Download failed"

# 2. Thêm domain chống thu hồi (Revoke) Apple của ông vào đây
echo "Adding Anti-Revoke domains..."
cat <<EOT >> oisd_list.txt
ocsp.apple.com
ocsp2.apple.com
ppq.apple.com
crl.apple.com
iadsdk.apple.com
EOT

# Sắp xếp và loại bỏ trùng lặp
sort -u oisd_list.txt -o oisd_list.txt

# 3. Tính toán và chia nhỏ list
total_lines=$(wc -l < oisd_list.txt)
echo "Total domains: $total_lines"

split -l ${MAX_LIST_SIZE} oisd_list.txt oisd_list.txt.

# 4. Lấy dữ liệu hiện tại từ Cloudflare
current_lists=$(curl -sSfL -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json")

# Lọc các list cũ có tiền tố "Block ads"
used_list_ids=($(echo "${current_lists}" | jq -r --arg PREFIX "$PREFIX" '.result[] | select(.name | contains($PREFIX)) | .id'))

# 5. Cập nhật hoặc Tạo mới list
list_counter=1
for file in oisd_list.txt.*; do
    formatted_counter=$(printf "%03d" "$list_counter")
    list_name="$PREFIX - $formatted_counter"
    
    # Chuyển file text sang định dạng JSON của Cloudflare
    items_json=$(jq -R -s 'split("\n") | map(select(length > 0) | { "value": . })' "$file")

    if [ $list_counter -le ${#used_list_ids[@]} ]; then
        list_id=${used_list_ids[$((list_counter-1))]}
        echo "Updating list: $list_name ($list_id)"
        
        # Lấy items cũ để xóa (Cloudflare PATCH yêu cầu append/remove)
        old_items=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}/items?limit=1000" \
            -H "Authorization: Bearer ${API_TOKEN}" | jq '.result | map({value: .value})')
            
        payload=$(jq -n --argjson append "$items_json" --argjson remove "$old_items" '{"append": $append, "remove": $remove}')
        curl -s -X PATCH "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
            -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$payload" > /dev/null
    else
        echo "Creating new list: $list_name"
        payload=$(jq -n --arg name "$list_name" --argjson items "$items_json" '{"name": $name, "type": "DOMAIN", "items": $items}')
        new_list=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
            -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$payload")
        used_list_ids+=($(echo "$new_list" | jq -r '.result.id'))
    fi
    list_counter=$((list_counter + 1))
done

# 6. Cập nhật Firewall Rule (Policy)
echo "Syncing Firewall Policy..."
conditions=""
for id in "${used_list_ids[@]}"; do
    [ -n "$conditions" ] && conditions="$conditions or "
    conditions="$conditions any(dns.domains in \$${id})"
done

# Tìm Policy ID cũ
policy_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
    -H "Authorization: Bearer ${API_TOKEN}" | jq -r --arg PREFIX "$PREFIX" '.result[] | select(.name == $PREFIX) | .id')

json_rule=$(jq -n --arg name "$PREFIX" --arg cond "$conditions" \
    '{"name": $name, "description": "Auto-sync from GitHub", "enabled": true, "action": "block", "filters": ["dns"], "traffic": $cond}')

if [ -n "$policy_id" ] && [ "$policy_id" != "null" ]; then
    curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/${policy_id}" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_rule" > /dev/null
else
    curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_rule" > /dev/null
fi

echo "Done! Cloudflare is synced."

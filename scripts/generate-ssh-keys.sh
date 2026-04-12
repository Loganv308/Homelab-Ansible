#!/usr/bin/env bash
set -euo pipefail

INVENTORY_FILE="../Inventory/inventory.yaml"
SSH_USER="root"
PARSE_SCRIPT="/root/parse_inventory.py"
HOSTS_FILE="/tmp/ansible_hosts.txt"

echo "🔐 Starting SSH key setup..."

cat > "$PARSE_SCRIPT" << 'PYEOF'
import sys, yaml

with open(sys.argv[1]) as f:
    inv = yaml.safe_load(f)

results = []

def parse_group(group):
    if not isinstance(group, dict):
        return
    hosts = group.get('hosts', {}) or {}
    for hostname, host_vars in hosts.items():
        if not isinstance(host_vars, dict):
            continue
        ip       = host_vars.get('ansible_host', '')
        key_path = host_vars.get('ansible_ssh_private_key_file', '')
        if ip and key_path and ip not in ('localhost', '127.0.0.1'):
            results.append((hostname, ip, key_path))
    reserved = {'hosts', 'vars'}
    for key, value in group.items():
        if key not in reserved and isinstance(value, dict):
            parse_group(value)

top = inv.get('all', inv)
children = top.get('children', {}) or {}
for group_name, group_data in children.items():
    parse_group(group_data or {})

for hostname, ip, key_path in results:
    print(f"{hostname}|{ip}|{key_path}")
PYEOF

python3 "$PARSE_SCRIPT" "$INVENTORY_FILE" > "$HOSTS_FILE"

if [ ! -s "$HOSTS_FILE" ]; then
    echo "❌ No hosts parsed from inventory. Check the path: $INVENTORY_FILE"
    rm -f "$PARSE_SCRIPT" "$HOSTS_FILE"
    exit 1
fi

HOST_COUNT=$(wc -l < "$HOSTS_FILE")
echo "📋 Found $HOST_COUNT hosts:"
awk -F'|' '{ printf "   %-25s %s\n", $1, $2 }' "$HOSTS_FILE"
echo ""

# Use fd 3 for the hosts file so stdin stays free for password prompts
while IFS='|' read -r HOSTNAME IP KEY_PATH <&3; do
    KEY_PATH="${KEY_PATH/#\~/$HOME}"
    PUB_KEY="${KEY_PATH}.pub"

    echo "----------------------------------------"
    echo "🖥️  Host: $HOSTNAME ($IP)"
    echo "🔑 Key:  $KEY_PATH"

    if [ ! -f "$KEY_PATH" ]; then
        echo "⚙️  Generating new ed25519 key..."
        mkdir -p "$(dirname "$KEY_PATH")"
        ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "ansible-$HOSTNAME"
    else
        echo "✔️  Key already exists, skipping generation"
    fi

    echo "📡 Copying public key to $SSH_USER@$IP ..."
    if ! ssh-copy-id \
        -i "$PUB_KEY" \
        -o StrictHostKeyChecking=accept-new \
        -o PubkeyAuthentication=no \
        -o PreferredAuthentications=password \
        "$SSH_USER@$IP"; then
        echo "⚠️  ssh-copy-id failed for $HOSTNAME ($IP) — skipping"
        continue
    fi

    echo "🔍 Verifying key-based login..."
    if ssh \
        -i "$KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o IdentitiesOnly=yes \
        -o BatchMode=yes \
        "$SSH_USER@$IP" "echo 'Key auth OK'"; then
        echo "✅ $HOSTNAME ($IP) — success"
    else
        echo "❌ $HOSTNAME ($IP) — key auth failed after copy, check manually"
    fi

done 3< "$HOSTS_FILE"

rm -f "$PARSE_SCRIPT" "$HOSTS_FILE"

echo ""
echo "✅ All hosts processed."

#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source 3xui-setup.sh
task_dir=$(mktemp -d)
cleanup_test() {
  rm -f "$task_dir/iptables" "$task_dir/ip6tables" "$task_dir/hook" "$task_dir/calls" \
    "$task_dir/iptables.nat.active" "$task_dir/ip6tables.nat.active" \
    "$task_dir/iptables.filter.active" "$task_dir/ip6tables.filter.active"
  rmdir "$task_dir"
}
trap cleanup_test EXIT
cat > "$task_dir/iptables" <<'EOF'
#!/bin/sh
state="$MOCK_STATE/$(basename "$0").$2.active"
case " $* " in
  *' -C '*) test -f "$state" ;;
  *' -I '*) touch "$state"; echo insert >> "$MOCK_STATE/calls" ;;
  *' -D '*) rm -f "$state"; echo delete >> "$MOCK_STATE/calls" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$task_dir/iptables"
cp "$task_dir/iptables" "$task_dir/ip6tables"
export MOCK_STATE="$task_dir"
export PATH="$task_dir:$PATH"
INFO_FILE="$task_dir/no-info"
ACME_PORT=18080
DOMAIN=example.invalid
ACME_HOOK="$task_dir/hook"
port_in_use() { return 1; }
precheck_port80
install_acme_hooks
"$ACME_HOOK" pre
"$ACME_HOOK" pre
[[ $(grep -c '^insert$' "$task_dir/calls") == 4 ]]
"$ACME_HOOK" post
"$ACME_HOOK" post
[[ $(grep -c '^delete$' "$task_dir/calls") == 4 ]]
[[ ! -e $task_dir/iptables.nat.active && ! -e $task_dir/ip6tables.nat.active ]]
[[ ! -e $task_dir/iptables.filter.active && ! -e $task_dir/ip6tables.filter.active ]]
for bad in 0 443 65536 invalid; do
  if (ACME_PORT=$bad; precheck_port80) 2>/dev/null; then
    echo "accepted invalid ACME listener: $bad" >&2; exit 1
  fi
done
echo 'ACME forwarding and cleanup checks passed'

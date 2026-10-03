#!/usr/bin/env bash
# Keep the kubeadm ClusterConfiguration (kube-system/kubeadm-config) in sync with the
# Entra ID authentication change on kube-apiserver, so `kubeadm upgrade` regenerates the
# static pod manifest with it.
#
#   kubeadm-config-entra.sh check      show the current apiServer block and its state
#   kubeadm-config-entra.sh enable     set apiServer extraArgs/extraVolumes for --authentication-config
#   kubeadm-config-entra.sh disable    set apiServer back to {}
#
# enable/disable: back up the ConfigMap to out/, build the new ClusterConfiguration without
# hand-editing (no tabs possible), check it (no tabs, valid YAML, expected structure), then
# write it back and verify. Nothing restarts; the ConfigMap is only read by kubeadm
# upgrade/join/init phase.
#
# Runs on the laptop: needs kubectl with admin access, jq, and ruby (built into macOS) for the
# YAML check. Optional: set CONTROL_PLANE_SSH (e.g. ubuntu@192.168.0.210, plus
# CONTROL_PLANE_SSH_KEY) to also have kubeadm on the control plane render the manifest from the
# new config (--dry-run), the only check that runs kubeadm's own validation.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../../.." && pwd)
CONTROL_PLANE_SSH=${CONTROL_PLANE_SSH:-}
CONTROL_PLANE_SSH_KEY=${CONTROL_PLANE_SSH_KEY:-}

AUTH_DIR=/etc/kubernetes/auth
AUTH_FILE=$AUTH_DIR/auth-config.yaml
TAB=$(printf '\t')
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ssh_cp() { ssh ${CONTROL_PLANE_SSH_KEY:+-i "$CONTROL_PLANE_SSH_KEY"} -o BatchMode=yes "$CONTROL_PLANE_SSH" "$@"; }
scp_cp() { scp -q ${CONTROL_PLANE_SSH_KEY:+-i "$CONTROL_PLANE_SSH_KEY"} -o BatchMode=yes "$1" "$CONTROL_PLANE_SSH:$2"; }
die() { echo "ERROR: $*" >&2; exit 1; }

enabled_block() {
  printf '%s\n' \
    'apiServer:' \
    '  extraArgs:' \
    '    - name: authentication-config' \
    "      value: $AUTH_FILE" \
    '  extraVolumes:' \
    '    - name: auth-config' \
    "      hostPath: $AUTH_DIR" \
    "      mountPath: $AUTH_DIR" \
    '      readOnly: true' \
    '      pathType: Directory'
}
disabled_block() { echo 'apiServer: {}'; }

# Top-level apiServer block: the "apiServer:" line plus following indented lines.
# Tab-indented lines count as part of it, so a broken hand edit is replaced too.
extract_block() { awk '/^apiServer:/{b=1; print; next} b && /^[ \t]/{print; next} {b=0}' "$1"; }
without_block() { awk '/^apiServer:/{b=1; next} b && /^[ \t]/{next} {b=0; print}' "$1"; }

state_of() {  # enabled | disabled | unknown
  local blk; blk=$(extract_block "$1")
  if [[ "$blk" == "$(enabled_block)" ]]; then echo enabled
  elif [[ "$blk" == "$(disabled_block)" ]]; then echo disabled
  else echo unknown; fi
}

# Refuse to replace an apiServer block that holds anything besides {} or our own settings
# (tabs aside), so unrelated settings like certSANs are never dropped silently.
assert_only_ours() {
  local blk; blk=$(extract_block "$1" | tr "$TAB" ' ' | sed 's/^ *//')
  local other
  other=$(grep -vE "^(apiServer:( \{\})?|extraArgs:|extraVolumes:|- name: (authentication-config|auth-config)|name: (authentication-config|auth-config)|value: $AUTH_FILE|hostPath: $AUTH_DIR|mountPath: $AUTH_DIR|readOnly: true|pathType: Directory)\$" <<<"$blk" || true)
  [[ -z "$other" ]] || die "apiServer block has settings this script doesn't manage; edit it by hand:
$other"
}

fetch() {
  kubectl -n kube-system get cm kubeadm-config -o json >"$WORK/cm.json"
  jq -r '.data.ClusterConfiguration' "$WORK/cm.json" >"$WORK/cc-old.yaml"
  grep -q '^kind: ClusterConfiguration$' "$WORK/cc-old.yaml" || die "kubeadm-config has no ClusterConfiguration"
}

cmd_check() {
  fetch
  echo "--- apiServer block (tabs shown as ^I):"
  extract_block "$WORK/cc-old.yaml" | sed "s/$TAB/^I/g"
  local tabs; tabs=$(grep -c "$TAB" "$WORK/cc-old.yaml" || true)
  echo "--- state: $(state_of "$WORK/cc-old.yaml"), tab characters: $tabs"
}

cmd_set() {  # enable | disable
  local want=$1
  fetch
  local before; before=$(state_of "$WORK/cc-old.yaml")
  if [[ "$before" == "${want}d" ]] && ! grep -q "$TAB" "$WORK/cc-old.yaml"; then
    echo "already ${want}d, nothing to do"; return
  fi
  assert_only_ours "$WORK/cc-old.yaml"

  mkdir -p "$REPO/out"
  local backup
  backup="$REPO/out/kubeadm-config.$(date +%Y%m%d-%H%M%S).json"
  cp "$WORK/cm.json" "$backup"
  echo "backup: ${backup#"$REPO"/}"

  # New ClusterConfiguration: the old one without its apiServer block, plus ours, keeping
  # kubeadm's alphabetical key order (apiServer sorts first).
  { if [[ $want == enable ]]; then enabled_block; else disabled_block; fi
    without_block "$WORK/cc-old.yaml"; } >"$WORK/cc-new.yaml"
  ! grep -q "$TAB" "$WORK/cc-new.yaml" || die "generated config contains a tab"
  [[ "$(state_of "$WORK/cc-new.yaml")" == "${want}d" ]] || die "generated config isn't in the ${want}d state"
  validate_yaml "$WORK/cc-new.yaml" "$want"
  echo "--- change:"; diff "$WORK/cc-old.yaml" "$WORK/cc-new.yaml" || true

  [[ -n "$CONTROL_PLANE_SSH" ]] && kubeadm_dry_run "$want"

  jq --rawfile cc "$WORK/cc-new.yaml" '.data.ClusterConfiguration = $cc | del(.metadata.managedFields)' "$WORK/cm.json" \
    | kubectl replace -f - >/dev/null
  kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | diff - "$WORK/cc-new.yaml" >/dev/null \
    || die "ConfigMap doesn't match what was written"
  echo "kubeadm-config: ${want}d (was: $before)"
}

# Parse the new ClusterConfiguration as YAML and check the apiServer structure.
validate_yaml() {
  command -v ruby >/dev/null || { echo "ruby not found, skipping YAML check"; return; }
  ruby -ryaml -e '
    c = YAML.safe_load(File.read(ARGV[0]))
    abort "kind is not ClusterConfiguration" unless c["kind"] == "ClusterConfiguration"
    api = c["apiServer"] || {}
    if ARGV[1] == "enable"
      args = api["extraArgs"] || []
      vols = api["extraVolumes"] || []
      abort "extraArgs wrong: #{args}" unless args == [{ "name" => "authentication-config", "value" => "#{ARGV[2]}/auth-config.yaml" }]
      abort "extraVolumes wrong: #{vols}" unless vols == [{ "name" => "auth-config", "hostPath" => ARGV[2], "mountPath" => ARGV[2],
                                                           "readOnly" => true, "pathType" => "Directory" }]
    else
      abort "apiServer is not empty: #{api}" unless api == {}
    end
    puts "YAML check: valid ClusterConfiguration, apiServer as expected"
  ' "$1" "$2" "$AUTH_DIR" || die "YAML check failed"
}

kubeadm_dry_run() {
  local want=$1
  echo "--- kubeadm dry run on $CONTROL_PLANE_SSH:"
  scp_cp "$WORK/cc-new.yaml" /tmp/kubeadm-cc-check.yaml
  ssh_cp "sudo bash -s" "$want" "$AUTH_DIR" <<'REMOTE'
set -euo pipefail
want=$1; auth_dir=$2
out=$(kubeadm init phase control-plane apiserver --config /tmp/kubeadm-cc-check.yaml --dry-run 2>&1) \
  || { echo "$out" | tail -5; rm -f /tmp/kubeadm-cc-check.yaml; exit 1; }
dir=$(echo "$out" | grep -oE '/etc/kubernetes/tmp/kubeadm-init-dryrun[0-9]+' | head -1)
gen=$dir/kube-apiserver.yaml
flag=$(grep -c -- "--authentication-config=$auth_dir/auth-config.yaml" "$gen" || true)
mount=$(grep -c "mountPath: $auth_dir\$" "$gen" || true)
echo "kubeadm accepted the config; generated manifest has: authentication-config flag=$flag, auth mount=$mount"
live=/etc/kubernetes/manifests/kube-apiserver.yaml
if diff <(sort "$live") <(sort "$gen") >/dev/null; then
  echo "generated manifest == live manifest (ignoring line order)"
else
  echo "generated manifest differs from the live manifest (ignoring line order):"
  diff <(sort "$live") <(sort "$gen") | grep '^[<>]' | sed 's/^/  /' || true
fi
rm -rf "$dir" /tmp/kubeadm-cc-check.yaml
if [[ $want == enable ]]; then [[ $flag == 1 && $mount == 1 ]]; else [[ $flag == 0 && $mount == 0 ]]; fi \
  || { echo "unexpected flag/mount count for $want"; exit 1; }
REMOTE
}

case "${1:-}" in
  check)   cmd_check ;;
  enable)  cmd_set enable ;;
  disable) cmd_set disable ;;
  *) awk 'NR>1 && /^#/{sub(/^# ?/, ""); print; next} NR>1{exit}' "$0"; exit 2 ;;
esac

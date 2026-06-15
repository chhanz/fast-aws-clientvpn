#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mgt-clientvpn.sh - AWS Client VPN integrated management script (single entry point)
#
# This shell handles certificate "creation"; CloudFormation (clientvpn.yaml)
# handles the "state" of AWS resources. The two roles are kept separate.
#
# Usage order: configure -> deploy -> status -> gen -> destroy
# See README.md or `./mgt-clientvpn.sh help` for details.
# =============================================================================

# ===== Fixed script values (environment values are loaded only from clientvpn.conf) =====
STACK=clientvpn-stack
CERT_TAG="clientvpn-server"     # ACM tag = single source of truth for idempotency
TEMPLATE_FILE="clientvpn.yaml"
EASYRSA_REPO="https://github.com/OpenVPN/easy-rsa"

# Directory where this script lives (so conf/template are always found in the same place, no matter where it is run from)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/clientvpn.conf"
CERT_DIR="$SCRIPT_DIR/clientvpn-certs"   # certificates are kept next to the script (current path)

# REGION/VPC_ID/SUBNET_ID/CLIENT_CIDR/TARGET_CIDR/SPLIT_TUNNEL/DNS_SERVERS are injected by
# load_conf via source (SPLIT_TUNNEL is overridden to false only on deploy --full-tunnel).
# DNS_SERVERS defaults to 169.254.169.253 (AWS Route 53 Resolver) if absent in conf.

# ===== Common helpers =====
err()  { echo "[X] $*" >&2; }
warn() { echo "[!] $*" >&2; }
info() { echo "[*] $*"; }
ok()   { echo "[OK] $*"; }

# Called on entry to every command except configure. If conf is missing, print guidance and exit.
load_conf() {
  if [ ! -f "$CONF_FILE" ]; then
    err "Config file not found. Run ./mgt-clientvpn.sh configure first"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$CONF_FILE"
}

# ===== Idempotent ACM lookup: find the ARN tagged Name=clientvpn-server =====
# Does not rely on the presence of local files (which breaks on host reinstall). The ACM tag is the single source of truth.
find_cert_arn() {
  local arn tag
  aws acm list-certificates --region "$REGION" \
    --query "CertificateSummaryList[].CertificateArn" --output text 2>/dev/null \
  | tr '\t' '\n' | while read -r arn; do
      [ -z "$arn" ] && continue
      tag=$(aws acm list-tags-for-certificate --certificate-arn "$arn" --region "$REGION" \
            --query "Tags[?Key=='Name']|[0].Value" --output text 2>/dev/null || true)
      if [ "$tag" = "$CERT_TAG" ]; then
        echo "$arn"
        break
      fi
    done
}

# =============================================================================
# configure - interactive input -> format validation -> live validation (graceful) -> save conf
# =============================================================================
cmd_configure() {
  if [ -f "$CONF_FILE" ]; then
    echo "Current settings:"
    cat "$CONF_FILE"
    echo
  fi

  local region vpc subnet ccidr tcidr split dns
  read -rp "Region [ap-northeast-2]: " region;        region=${region:-ap-northeast-2}
  read -rp "VPC ID: " vpc
  read -rp "Subnet ID: " subnet
  read -rp "Client CIDR (/22~/12) [10.100.0.0/22]: " ccidr; ccidr=${ccidr:-10.100.0.0/22}
  read -rp "Internal network CIDR (to authorize) [172.31.0.0/16]: " tcidr;  tcidr=${tcidr:-172.31.0.0/16}
  read -rp "Split Tunnel? (true/false) [true]: " split;     split=${split:-true}
  read -rp "DNS servers (comma-separated) [169.254.169.253]: " dns; dns=${dns:-169.254.169.253}

  # --- 1) Format validation (offline, always performed) ---
  if [[ ! $vpc =~ ^vpc- ]]; then
    err "Invalid VPC ID format (must start with vpc-): $vpc"; exit 1
  fi
  if [[ ! $subnet =~ ^subnet- ]]; then
    err "Invalid Subnet ID format (must start with subnet-): $subnet"; exit 1
  fi

  # CLIENT_CIDR mask validation: reject if narrower than /22 (>22) or wider than /12 (<12)
  if [[ ! $ccidr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    err "Invalid Client CIDR format (e.g. 10.100.0.0/22): $ccidr"; exit 1
  fi
  local mask="${ccidr##*/}"
  if [ "$mask" -gt 22 ]; then
    err "Client CIDR mask is too narrow (/$mask). It must be /22 or wider (Client VPN minimum requirement)."; exit 1
  fi
  if [ "$mask" -lt 12 ]; then
    err "Client CIDR mask is too wide (/$mask). It cannot be wider than /12."; exit 1
  fi

  if [[ ! $tcidr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    err "Invalid internal network CIDR format (e.g. 172.31.0.0/16): $tcidr"; exit 1
  fi

  # CLIENT_CIDR <-> TARGET_CIDR overlap warning (warn only if network addresses are identical)
  if [ "${ccidr%%/*}" = "${tcidr%%/*}" ]; then
    warn "Client CIDR and internal network CIDR have the same network address. Check for possible routing conflicts."
  fi

  # --- 2) Live validation (AWS CLI, graceful: SKIP if no permission) ---
  local out rc
  out=$(aws ec2 describe-subnets --subnet-ids "$subnet" --region "$region" \
        --query 'Subnets[0].VpcId' --output text 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] || echo "$out" | grep -qE 'AccessDenied|UnauthorizedOperation'; then
    warn "No AWS CLI permission, so automatic validation is skipped. Please verify manually:"
    echo "    - that the subnet actually belongs to the VPC ($subnet -> $vpc)"
    echo "    - Console: VPC > Subnets > the VPC column of this subnet"
  elif [ "$out" != "$vpc" ]; then
    err "Subnet does not belong to the given VPC (actual: $out). Aborting."; exit 1
  else
    ok "Subnet-VPC match confirmed"
  fi

  # --- 3) Save (key=value) ---
  cat > "$CONF_FILE" <<EOF
REGION=$region
VPC_ID=$vpc
SUBNET_ID=$subnet
CLIENT_CIDR=$ccidr
TARGET_CIDR=$tcidr
SPLIT_TUNNEL=$split
DNS_SERVERS=$dns
EOF
  ok "Saved -> $CONF_FILE"
}

# =============================================================================
# deploy [--full-tunnel] - obtain certificate (ACM) -> CFn deploy -> generate .ovpn
# =============================================================================

# Generate CA/server/client certificates with easy-rsa and import into ACM. Returns the resulting ARN on stdout.
create_and_import_cert() {
  local easyrsa_dir="$CERT_DIR/easy-rsa"
  mkdir -p "$CERT_DIR"

  # Obtain easy-rsa
  if [ ! -d "$easyrsa_dir" ]; then
    info "Downloading easy-rsa..." >&2
    git clone "$EASYRSA_REPO" "$easyrsa_dir" >&2
  fi

  local er="$easyrsa_dir/easyrsa3"
  (
    cd "$er"
    info "Initializing PKI and generating certificates (CA/server/client1)..." >&2
    ./easyrsa init-pki >&2
    ./easyrsa --batch build-ca nopass >&2
    ./easyrsa --batch --san=DNS:server build-server-full server nopass >&2
    ./easyrsa --batch build-client-full client1 nopass >&2
    # Restrict permissions right after key generation
    chmod 600 pki/private/*.key
  )

  # Copy the generated artifacts into CERT_DIR (reused by gen / .ovpn insertion)
  cp "$er/pki/ca.crt"                  "$CERT_DIR/ca.crt"
  cp "$er/pki/issued/server.crt"       "$CERT_DIR/server.crt"
  cp "$er/pki/private/server.key"      "$CERT_DIR/server.key"
  cp "$er/pki/issued/client1.crt"      "$CERT_DIR/client1.crt"
  cp "$er/pki/private/client1.key"     "$CERT_DIR/client1.key"
  chmod 600 "$CERT_DIR"/*.key

  info "Importing the server certificate into ACM..." >&2
  local arn
  arn=$(aws acm import-certificate \
        --certificate     "fileb://$CERT_DIR/server.crt" \
        --private-key     "fileb://$CERT_DIR/server.key" \
        --certificate-chain "fileb://$CERT_DIR/ca.crt" \
        --tags "Key=Name,Value=$CERT_TAG" \
        --region "$REGION" \
        --query 'CertificateArn' --output text)
  echo "$arn"
}

cmd_deploy() {
  # [1] Look up an existing certificate by ACM tag (single idempotency rule)
  local arn
  arn=$(find_cert_arn)

  if [ -z "$arn" ]; then
    info "No certificate tagged Name=$CERT_TAG found. Creating a new one."
    arn=$(create_and_import_cert)
  else
    info "Reusing existing certificate: $arn"
  fi

  if [ -z "$arn" ]; then
    err "Failed to obtain a certificate ARN."; exit 1
  fi

  # DNS_SERVERS may be absent in older conf files; default to the AWS Route 53 Resolver address.
  DNS_SERVERS="${DNS_SERVERS:-169.254.169.253}"

  # [4] CloudFormation deploy
  info "Deploying CloudFormation stack: $STACK (SplitTunnel=$SPLIT_TUNNEL)"
  aws cloudformation deploy \
    --stack-name "$STACK" \
    --template-file "$SCRIPT_DIR/$TEMPLATE_FILE" \
    --parameter-overrides \
        ServerCertArn="$arn" \
        ClientCidr="$CLIENT_CIDR" \
        VpcId="$VPC_ID" \
        SubnetId="$SUBNET_ID" \
        TargetCidr="$TARGET_CIDR" \
        SplitTunnel="$SPLIT_TUNNEL" \
        DnsServers="$DNS_SERVERS" \
    --region "$REGION"

  ok "Deployment complete."

  # [5] .ovpn export + insert client cert/key
  generate_ovpn
}

# =============================================================================
# Generate .ovpn: export endpoint config, then insert <cert>/<key>
# (shared by the end of deploy and the gen command)
# =============================================================================
generate_ovpn() {
  local ep_id ovpn_base ovpn_out
  ep_id=$(aws ec2 describe-client-vpn-endpoints --region "$REGION" \
          --query "ClientVpnEndpoints[?Tags[?Key=='aws:cloudformation:stack-name' && Value=='$STACK']].ClientVpnEndpointId | [0]" \
          --output text 2>/dev/null || true)

  # If the tag-based lookup is empty, try to get it from the stack outputs
  if [ -z "$ep_id" ] || [ "$ep_id" = "None" ]; then
    ep_id=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
            --query "Stacks[0].Outputs[?OutputKey=='ClientVpnEndpointId'].OutputValue | [0]" \
            --output text 2>/dev/null || true)
  fi

  if [ -z "$ep_id" ] || [ "$ep_id" = "None" ]; then
    err "Client VPN endpoint not found. Check the deployment state."; exit 1
  fi

  ovpn_base="$CERT_DIR/${STACK}-base.ovpn"
  ovpn_out="$CERT_DIR/${STACK}-client1.ovpn"

  info "Downloading endpoint configuration: $ep_id"
  aws ec2 export-client-vpn-client-configuration \
    --client-vpn-endpoint-id "$ep_id" \
    --region "$REGION" \
    --output text > "$ovpn_base"

  # The client cert/key must exist locally to be inserted
  if [ ! -f "$CERT_DIR/client1.crt" ] || [ ! -f "$CERT_DIR/client1.key" ]; then
    warn "client1 certificate/key not found locally, so it could not be auto-inserted into the .ovpn."
    warn "Saved the base configuration only: $ovpn_base"
    warn "Make sure you ran deploy once on the host that holds the certificates."
    return 0
  fi

  {
    cat "$ovpn_base"
    echo
    echo "<cert>"
    cat "$CERT_DIR/client1.crt"
    echo "</cert>"
    echo "<key>"
    cat "$CERT_DIR/client1.key"
    echo "</key>"
  } > "$ovpn_out"
  chmod 600 "$ovpn_out"

  ok "Client configuration generated: $ovpn_out"
}

# =============================================================================
# destroy - delete stack -> wait -> clean up ACM certificate (order matters)
# =============================================================================
cmd_destroy() {
  local a
  read -rp "Really delete? (yes): " a
  if [ "$a" != "yes" ]; then
    info "Cancelled."; exit 1
  fi

  info "Requesting stack deletion: $STACK"
  aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"

  info "Waiting for stack deletion to complete... (must finish first since the endpoint references the certificate)"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION"
  ok "Stack deletion complete."

  # The certificate can only be deleted after the stack (endpoint) is gone
  local arn
  arn=$(find_cert_arn)
  if [ -n "$arn" ]; then
    info "Deleting ACM certificate: $arn"
    aws acm delete-certificate --certificate-arn "$arn" --region "$REGION"
    ok "Certificate deletion complete."
  else
    info "No certificate to delete (tag Name=$CERT_TAG)."
  fi
}

# =============================================================================
# status - show stack/endpoint/association/certificate/tunnel mode
# =============================================================================
cmd_status() {
  echo "=== Stack status ==="
  aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].StackStatus" --output text --no-cli-pager 2>/dev/null \
    || echo "(stack not found or not accessible)"

  echo
  echo "=== Client VPN endpoint ==="
  aws ec2 describe-client-vpn-endpoints --region "$REGION" \
    --query "ClientVpnEndpoints[?Tags[?Key=='aws:cloudformation:stack-name' && Value=='$STACK']].[ClientVpnEndpointId, Status.Code, SplitTunnel, ClientCidrBlock]" \
    --output table --no-cli-pager 2>/dev/null \
    || echo "(endpoint not accessible)"

  echo
  echo "=== Associated target networks (subnets) ==="
  local ep_id
  ep_id=$(aws ec2 describe-client-vpn-endpoints --region "$REGION" \
          --query "ClientVpnEndpoints[?Tags[?Key=='aws:cloudformation:stack-name' && Value=='$STACK']].ClientVpnEndpointId | [0]" \
          --output text 2>/dev/null || true)
  if [ -n "$ep_id" ] && [ "$ep_id" != "None" ]; then
    aws ec2 describe-client-vpn-target-networks \
      --client-vpn-endpoint-id "$ep_id" --region "$REGION" \
      --query "ClientVpnTargetNetworks[].[TargetNetworkId, Status.Code]" \
      --output table --no-cli-pager 2>/dev/null || echo "(target networks not accessible)"
  else
    echo "(no endpoint)"
  fi

  echo
  echo "=== Certificate ARN (tag Name=$CERT_TAG) ==="
  find_cert_arn || true
  echo

  echo "=== Tunnel mode ==="
  echo "Current conf SPLIT_TUNNEL=$SPLIT_TUNNEL ($([ "$SPLIT_TUNNEL" = "true" ] && echo 'Split: only internal network over VPN' || echo 'Full: all traffic over VPN'))"
  echo "DNS servers pushed to clients: ${DNS_SERVERS:-169.254.169.253}"
  echo
  warn "Note: Client CIDR($CLIENT_CIDR) cannot be changed after the endpoint is created. To change it, destroy and redeploy."
}

# =============================================================================
# gen - regenerate/re-download the .ovpn for the deployed endpoint
# =============================================================================
cmd_gen() {
  generate_ovpn
}

# =============================================================================
# help
# =============================================================================
cmd_help() {
  cat <<'EOF'
AWS Client VPN integrated management script

Usage:
  ./mgt-clientvpn.sh configure            Interactively enter environment values -> save clientvpn.conf
  ./mgt-clientvpn.sh deploy               Obtain certificate + deploy VPN + generate .ovpn (Split Tunnel by default)
  ./mgt-clientvpn.sh deploy --full-tunnel Deploy in Full Tunnel mode, sending all traffic over the VPN
  ./mgt-clientvpn.sh status               Show stack/endpoint/association/certificate/tunnel mode
  ./mgt-clientvpn.sh gen                  Regenerate/re-download the .ovpn for the deployed endpoint
  ./mgt-clientvpn.sh destroy              Delete stack -> wait -> clean up certificate (yes confirmation)
  ./mgt-clientvpn.sh help                 This help

Recommended order: configure -> deploy -> status -> gen -> destroy
EOF
}

# ===== Argument parsing =====
case "${1:-help}" in
  configure) cmd_configure ;;
  deploy)
    load_conf
    if [ "${2:-}" = "--full-tunnel" ]; then
      SPLIT_TUNNEL=false
      info "Deploying in Full Tunnel mode (SPLIT_TUNNEL=false)."
    fi
    cmd_deploy
    ;;
  destroy) load_conf; cmd_destroy ;;
  status)  load_conf; cmd_status ;;
  gen)     load_conf; cmd_gen ;;
  help|-h|--help) cmd_help ;;
  *)
    err "Unknown command: $1"
    cmd_help
    exit 1
    ;;
esac

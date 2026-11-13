#!/usr/bin/env bash
# Optional demo Client VPN helper for terraform/modules/vpn.
#
#   deploy/setup-vpn.sh certs   --name <prefix> [--region <r>] [--dir <d>] [--force] [--generate-only | --dry-run]
#   deploy/setup-vpn.sh profile --name <prefix> [--region <r>] [--dir <d>]
#
# certs:   creates a local CA, a server certificate and ONE shared client
#          certificate with openssl, verifies the chains, imports the server
#          and client certificates into ACM and prints the tfvars lines.
#          Private keys stay on this machine and in ACM; they never touch
#          Terraform state.
# profile: after deploy, reads the endpoint ID from SSM, exports the Client
#          VPN configuration and writes a ready-to-import .ovpn profile with
#          the client certificate and key.
#
# Demo and testing only; use Direct Connect, Transit Gateway or your own VPN
# for regular access. No secret is ever printed; the .ovpn file is written mode 600.
set -euo pipefail

KEY_BITS=2048 # Client VPN accepts RSA 1024/2048 only
CA_DAYS=3650
LEAF_DAYS=825
CLIENT_NAME="client1"

usage() {
  cat <<'EOF'
Optional demo Client VPN helper for terraform/modules/vpn.

Usage:
  deploy/setup-vpn.sh certs   --name <prefix> [--region <r>] [--dir <d>] [--force] [--generate-only | --dry-run]
  deploy/setup-vpn.sh profile --name <prefix> [--region <r>] [--dir <d>]

certs:   creates a local CA, a server certificate and ONE shared client
         certificate, verifies the chains, imports the server and client
         certificates into ACM and prints the tfvars lines.
profile: after deploy, reads the endpoint ID from SSM, exports the Client VPN
         configuration and writes a ready-to-import .ovpn profile. The profile
         embeds the CA certificate, so the VPN client trusts the endpoint
         without any change to the operating system's trust store.

Options:
  --name <prefix>   Deployment name (the Terraform deployment_name). Required.
  --region <r>      AWS region (defaults to AWS_REGION / AWS_DEFAULT_REGION).
  --dir <d>         Certificate directory (default ~/.llm-gateway-vpn/<prefix>).
  --force           certs: regenerate certificates even if they already exist.
  --generate-only   certs: offline mode — generate and verify the certificates
                    in the certificate directory but do NOT import into ACM;
                    no AWS calls, no AWS CLI needed. Import later by re-running
                    'certs' without this flag.
  --dry-run         certs: offline self-test — like --generate-only but in a
                    fresh temporary directory.
  -h, --help        Show this help.

Demo and testing only; use Direct Connect, Transit Gateway or your own VPN for regular access.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed."
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
[[ $# -gt 0 ]] || { usage; exit 2; }
CMD="$1"
shift
case "$CMD" in
  certs | profile) ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; die "unknown subcommand '$CMD'" ;;
esac

NAME=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
DIR=""
FORCE=false
GENERATE_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --generate-only) GENERATE_ONLY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

[[ -n "$NAME" ]] || die "--name is required."
# Same rule as the Terraform deployment_name validation.
[[ "$NAME" =~ ^[a-z][a-z0-9-]{0,19}$ ]] ||
  die "--name must start with a lowercase letter and contain only lowercase letters, digits and hyphens (max 20 characters)."
if [[ "$DRY_RUN" == true || "$GENERATE_ONLY" == true ]]; then
  [[ "$CMD" == "certs" ]] || die "--dry-run and --generate-only only apply to 'certs'."
fi
if [[ "$DRY_RUN" == true ]]; then
  DIR="${DIR:-$(mktemp -d "${TMPDIR:-/tmp}/llm-gateway-vpn-${NAME}.XXXXXX")}"
elif [[ "$GENERATE_ONLY" == true ]]; then
  DIR="${DIR:-$HOME/.llm-gateway-vpn/$NAME}"
else
  [[ -n "$REGION" ]] || die "--region is required (or set AWS_REGION)."
  DIR="${DIR:-$HOME/.llm-gateway-vpn/$NAME}"
fi

DOMAIN="${NAME}.vpn.internal"
SERVER_CN="server.${DOMAIN}"
CLIENT_CN="${CLIENT_NAME}.${DOMAIN}"
need openssl

# ---------------------------------------------------------------------------
# certs
# ---------------------------------------------------------------------------
gen_key() {
  openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${KEY_BITS}" -out "$1" 2>/dev/null
}

# sign_leaf <basename> <cn> <serverAuth|clientAuth>
sign_leaf() {
  local base="$1" cn="$2" eku="$3" ext="$DIR/$1.ext"
  cat >"$ext" <<EOF
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = ${eku}
subjectAltName = DNS:${cn}
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid, issuer
EOF
  gen_key "$DIR/$base.key"
  openssl req -new -key "$DIR/$base.key" -subj "/CN=${cn}" -out "$DIR/$base.csr"
  openssl x509 -req -in "$DIR/$base.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" \
    -CAcreateserial -days "$LEAF_DAYS" -sha256 -extfile "$ext" -out "$DIR/$base.crt" 2>/dev/null
  rm -f "$DIR/$base.csr" "$ext"
}

generate_certs() {
  if [[ -f "$DIR/ca.crt" && -f "$DIR/server.crt" && -f "$DIR/client.crt" && "$FORCE" != true ]]; then
    echo "Reusing existing certificates in $DIR (use --force to regenerate)."
    return
  fi

  echo "Generating CA, server and client certificates in $DIR ..."
  gen_key "$DIR/ca.key"
  openssl req -x509 -new -key "$DIR/ca.key" -sha256 -days "$CA_DAYS" \
    -subj "/CN=${NAME} demo VPN CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$DIR/ca.crt"
  sign_leaf server "$SERVER_CN" serverAuth
  sign_leaf client "$CLIENT_CN" clientAuth
  chmod 600 "$DIR"/*.key
}

# Built-in self-test: both leaves must chain to the CA with the right key usage.
verify_certs() {
  openssl verify -CAfile "$DIR/ca.crt" -purpose sslserver "$DIR/server.crt" >/dev/null ||
    die "server certificate does not verify against the CA for serverAuth."
  openssl verify -CAfile "$DIR/ca.crt" -purpose sslclient "$DIR/client.crt" >/dev/null ||
    die "client certificate does not verify against the CA for clientAuth."
  echo "Verified: server (serverAuth) and client (clientAuth) chain to the CA."
}

# import_cert <basename> <arn-file>; re-imports in place if an ARN was saved before.
import_cert() {
  local base="$1" arn_file="$DIR/$2" args=()
  if [[ -s "$arn_file" ]]; then
    args+=(--certificate-arn "$(cat "$arn_file")")
  else
    args+=(--tags "Key=Name,Value=${NAME}-vpn-${base}")
  fi
  aws acm import-certificate \
    --region "$REGION" \
    --certificate "fileb://$DIR/$base.crt" \
    --private-key "fileb://$DIR/$base.key" \
    --certificate-chain "fileb://$DIR/ca.crt" \
    "${args[@]}" \
    --query CertificateArn --output text >"$arn_file"
  grep -q '^arn:aws' "$arn_file" ||
    die "ACM import of the $base certificate returned no ARN."
  cat "$arn_file"
}

cmd_certs() {
  umask 077
  mkdir -p "$DIR"
  chmod 700 "$DIR"
  generate_certs
  verify_certs

  if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run: certificates generated and verified in $DIR; nothing imported."
    return
  fi
  if [[ "$GENERATE_ONLY" == true ]]; then
    echo "Generate only: certificates generated and verified in $DIR; nothing imported."
    echo "Import into ACM later with: $0 certs --name ${NAME} --region <region>"
    return
  fi

  need aws
  echo "Importing certificates into ACM ($REGION) ..."
  local server_arn client_arn
  server_arn="$(import_cert server server.arn)"
  # Client VPN validates client certs against the chain of this ACM certificate (our CA).
  client_arn="$(import_cert client client-root.arn)"

  cat <<EOF

Add to deploy/terraform.tfvars:

create_vpn                      = true
vpn_server_certificate_arn      = "${server_arn}"
vpn_client_root_certificate_arn = "${client_arn}"

After deploy/deploy.sh, run:
  $0 profile --name ${NAME} --region ${REGION}
EOF
}

# ---------------------------------------------------------------------------
# profile
# ---------------------------------------------------------------------------
detect_client() {
  case "$(uname -s)" in
    Darwin)
      if [[ -d "/Applications/Tunnelblick.app" ]]; then echo tunnelblick; return; fi
      if [[ -d "/Applications/AWS VPN Client/AWS VPN Client.app" ]]; then echo aws; return; fi
      ;;
    Linux)
      if command -v openvpn >/dev/null 2>&1; then echo openvpn; return; fi
      if [[ -x /opt/awsvpnclient/AWS\ VPN\ Client ]]; then echo aws; return; fi
      ;;
  esac
  if command -v openvpn >/dev/null 2>&1; then echo openvpn; return; fi
  echo none
}

cmd_profile() {
  need aws
  [[ -f "$DIR/client.crt" && -f "$DIR/client.key" && -f "$DIR/ca.crt" ]] ||
    die "client certificate not found in $DIR; run '$0 certs --name $NAME' first."

  local param="/${NAME}/vpn/endpoint-id" endpoint_id ovpn tmp
  endpoint_id="$(aws ssm get-parameter --region "$REGION" --name "$param" \
    --query Parameter.Value --output text 2>/dev/null || true)"
  [[ "$endpoint_id" == cvpn-endpoint-* ]] ||
    die "no Client VPN endpoint ID at SSM $param in $REGION (is create_vpn = true and deployed?)."
  echo "Client VPN endpoint: $endpoint_id"

  umask 077
  ovpn="$DIR/${NAME}.ovpn"
  tmp="$(mktemp "$DIR/.ovpn.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT

  aws ec2 export-client-vpn-client-configuration --region "$REGION" \
    --client-vpn-endpoint-id "$endpoint_id" \
    --query ClientConfiguration --output text >"$tmp"
  {
    echo
    echo "<cert>"
    openssl x509 -in "$DIR/client.crt"
    echo "</cert>"
    echo "<key>"
    cat "$DIR/client.key"
    echo "</key>"
  } >>"$tmp"
  mv "$tmp" "$ovpn"
  chmod 600 "$ovpn"
  trap - EXIT
  echo "Wrote $ovpn"

  echo
  case "$(detect_client)" in
    tunnelblick)
      echo "Tunnelblick detected. Import and connect:"
      echo "  open \"$ovpn\"   # then connect from the Tunnelblick menu bar icon"
      ;;
    aws)
      echo "AWS VPN Client detected. File > Manage Profiles > Add Profile,"
      echo "select $ovpn, then Connect."
      ;;
    openvpn)
      echo "OpenVPN detected. Connect with:"
      echo "  sudo openvpn --config \"$ovpn\""
      ;;
    *)
      echo "No VPN client found. Install one of:"
      echo "  Tunnelblick (macOS):  brew install --cask tunnelblick"
      echo "  AWS VPN Client:       https://aws.amazon.com/vpn/client-vpn-download/"
      echo "  OpenVPN (Linux):      your package manager (e.g. apt install openvpn)"
      echo "then import $ovpn."
      ;;
  esac
  echo
  echo "The profile contains the shared client private key: do not commit or share it."
}

case "$CMD" in
  certs) cmd_certs ;;
  profile) cmd_profile ;;
esac

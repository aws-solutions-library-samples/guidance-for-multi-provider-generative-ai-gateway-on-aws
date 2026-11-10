#!/bin/bash
# Optional helper: copy the upstream LiteLLM image into a registry you control
# (by default this account's ECR), so the gateway tasks can pull it without
# reaching ghcr.io. Nothing in Terraform or deploy.sh calls this script; use the
# printed URI as the app's image_uri variable. Run with --help for details.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_TF="${SCRIPT_DIR}/../terraform/app/container.tf"
SOURCE_REPO="ghcr.io/berriai/litellm"
# BerriAI publishes the public key that signs a release as cosign.pub in that
# release's tag; the key can change between releases, so it is read from the
# tag of the image being copied unless --cosign-key names another key.
COSIGN_KEY=""

usage() {
  cat <<'EOF'
Usage: deploy/mirror-image.sh [options]

Copies the official LiteLLM container image (ghcr.io/berriai/litellm) into a
registry you control and prints the resulting image URI. The gateway does not
need this: by default its tasks pull the pinned upstream image from ghcr.io.
Use it when the tasks cannot reach ghcr.io (no internet egress, or a policy
that only allows images from your own registry), then set in
deploy/terraform.tfvars:

  image_uri = "<the URI this script prints>"

Options:
  --version <tag>      Image tag to copy, e.g. v1.2.3. Default: the image
                       pinned in terraform/app/container.tf (tag@digest),
                       pulled by its digest. Another tag is pulled by tag.
  --cosign-key <ref>   Public key to verify the signature with (URL or file).
                       Default: cosign.pub in the copied release's tag.
  --platform <os/arch> Platform to copy. Default linux/arm64, the gateway
                       tasks' architecture (Graviton); linux/amd64 is offered
                       for other consumers of the mirrored image.
  --registry <prefix>  Push to this registry/namespace instead of ECR, e.g.
                       registry.example.com/platform. You must already be
                       logged in to it (docker login). No AWS calls are made.
  --repository <name>  Repository name. Default: litellm.
  --region <region>    ECR region. Default: AWS_REGION, then the AWS CLI's
                       configured region. Ignored with --registry.
  --dry-run            Pull and verify the upstream image only; push nothing
                       and make no AWS calls.
  --skip-verify        Copy without verifying the upstream signature. Without
                       this flag the script refuses to run when cosign is not
                       installed.
  -h, --help           Show this help.

With the default ECR target the script creates the repository if it is
missing (immutable tags, scan on push), logs Docker in to ECR and pushes.
The AWS identity needs ecr:DescribeRepositories, ecr:CreateRepository,
ecr:GetAuthorizationToken, ecr:BatchCheckLayerAvailability,
ecr:InitiateLayerUpload, ecr:UploadLayerPart, ecr:CompleteLayerUpload,
ecr:PutImage, ecr:DescribeImages and sts:GetCallerIdentity.

The upstream image signature is verified with cosign before anything is
pushed; a failed verification stops the script. cosign is required unless
--skip-verify is given.

By default the script copies exactly the image pinned in
terraform/app/container.tf: it pulls by the pinned digest and stops if the
pulled image has any other digest, so a re-pushed upstream tag is never
mirrored. The pin also applies when --version names the pinned tag.

The printed URI is pinned by digest (repository@sha256:...), so the tasks run
exactly the image that was verified and pushed. Upstream releases are
multi-platform indexes and only the --platform image is copied, so the printed
digest is that platform's manifest digest from the verified index, not the
index digest pinned in container.tf. The script reads the digest back from the
target registry and stops if it is not that manifest.

Requires: docker (with a running daemon and buildx); python3; cosign (unless
--skip-verify); the AWS CLI for the ECR target.

Exit codes: 0 success, 1 failure, 2 usage error.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
usage_error() { echo "Error: $*" >&2; echo "Run '$0 --help' for usage." >&2; exit 2; }

VERSION="" COSIGN_KEY_OVERRIDE="" PLATFORM="linux/arm64" REGISTRY="" REPOSITORY="litellm" REGION="" DRY_RUN=false SKIP_VERIFY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --version | --cosign-key | --platform | --registry | --repository | --region)
      [ $# -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value."
      case "$1" in
        --version) VERSION="$2" ;;
        --cosign-key) COSIGN_KEY_OVERRIDE="$2" ;;
        --platform) PLATFORM="$2" ;;
        --registry) REGISTRY="${2%/}" ;;
        --repository) REPOSITORY="$2" ;;
        --region) REGION="$2" ;;
      esac
      shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-verify) SKIP_VERIFY=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done

# The pinned image (tag@digest) from container.tf.
PINNED_TAG="" PINNED_DIGEST=""
if [ -f "$CONTAINER_TF" ]; then
  PINNED="$(sed -n 's|.*"ghcr\.io/berriai/litellm:\([A-Za-z0-9_.-]*\)@\(sha256:[0-9a-f]\{64\}\)".*|\1 \2|p' "$CONTAINER_TF" | head -n 1)"
  PINNED_TAG="${PINNED%% *}" PINNED_DIGEST="${PINNED#* }"
fi
if [ -z "$VERSION" ]; then
  [ -n "$PINNED_TAG" ] && [ -n "$PINNED_DIGEST" ] ||
    usage_error "--version is required (no pinned tag@digest found in terraform/app/container.tf)."
  VERSION="$PINNED_TAG"
fi
EXPECTED_DIGEST=""
[ "$VERSION" != "$PINNED_TAG" ] || EXPECTED_DIGEST="$PINNED_DIGEST"
[[ "$VERSION" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || usage_error "--version must be an image tag, e.g. v1.2.3."
[[ "$PLATFORM" =~ ^linux/(arm64|amd64)$ ]] || usage_error "--platform must be linux/arm64 or linux/amd64."
[[ "$REPOSITORY" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || usage_error "--repository must be a lowercase repository name."

command -v docker >/dev/null 2>&1 || die "docker is required."
docker buildx version >/dev/null 2>&1 || die "docker buildx is required (it reads image digests from the registries)."
command -v python3 >/dev/null 2>&1 || die "python3 is required."
if [ "$SKIP_VERIFY" != true ] && ! command -v cosign >/dev/null 2>&1; then
  die "cosign is required to verify the upstream image signature (install it, or pass --skip-verify to copy unverified)."
fi
docker info >/dev/null 2>&1 || die "the Docker daemon is not running."

if [ -n "$EXPECTED_DIGEST" ]; then
  # The pinned image: pulled by digest, so a re-pushed tag cannot change it.
  SOURCE="${SOURCE_REPO}@${EXPECTED_DIGEST}"
  echo "Pulling ${SOURCE_REPO}:${VERSION}@${EXPECTED_DIGEST} (${PLATFORM}), the image pinned in container.tf"
else
  SOURCE="${SOURCE_REPO}:${VERSION}"
  echo "Pulling ${SOURCE} (${PLATFORM})"
fi
docker pull --quiet --platform "$PLATFORM" "$SOURCE" >/dev/null || die "could not pull ${SOURCE}."
SOURCE_DIGESTS="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$SOURCE" |
  sed -n "s|^${SOURCE_REPO}@||p")"
if [ -n "$EXPECTED_DIGEST" ]; then
  grep -qFx "$EXPECTED_DIGEST" <<<"$SOURCE_DIGESTS" ||
    die "the pulled image is not the pinned ${EXPECTED_DIGEST}; nothing was pushed."
  SOURCE_DIGEST="$EXPECTED_DIGEST"
else
  SOURCE_DIGEST="$(head -n 1 <<<"$SOURCE_DIGESTS")"
fi
[ -n "$SOURCE_DIGEST" ] || die "could not read the upstream digest of ${SOURCE}."
echo "Upstream digest: ${SOURCE_DIGEST}"

COSIGN_KEY="${COSIGN_KEY_OVERRIDE:-https://raw.githubusercontent.com/BerriAI/litellm/${VERSION}/cosign.pub}"
if [ "$SKIP_VERIFY" = true ]; then
  echo "--skip-verify: the upstream signature was NOT verified."
else
  cosign verify --key "$COSIGN_KEY" "${SOURCE_REPO}@${SOURCE_DIGEST}" >/dev/null ||
    die "cosign could not verify the signature of ${SOURCE_REPO}@${SOURCE_DIGEST}; nothing was pushed."
  echo "Signature verified with cosign (key: ${COSIGN_KEY})."
fi

# docker pushes only the pulled platform's image, so the target registry must
# end up with that platform's manifest from the verified index (or the
# verified manifest itself when the upstream image is single-platform).
# Docker's RepoDigests cannot be used for this: with the containerd image
# store it reports the index digest, which the push does not create.
EXPECTED_PUSHED="$(docker buildx imagetools inspect --raw "${SOURCE_REPO}@${SOURCE_DIGEST}" |
  python3 -I -c '
import json, sys
os_name, arch = sys.argv[1].split("/")
doc = json.load(sys.stdin)
if "manifests" not in doc:
    print(sys.argv[2])
else:
    for entry in doc["manifests"]:
        p = entry.get("platform") or {}
        if p.get("os") == os_name and p.get("architecture") == arch:
            print(entry["digest"])
            break
' "$PLATFORM" "$SOURCE_DIGEST")" || die "could not read the upstream manifest of ${SOURCE_REPO}@${SOURCE_DIGEST}."
[[ "$EXPECTED_PUSHED" == sha256:* ]] || die "${SOURCE_REPO}@${SOURCE_DIGEST} has no ${PLATFORM} image."
echo "Verified ${PLATFORM} manifest: ${EXPECTED_PUSHED}"

registry_digest() { # image reference -> manifest digest as stored in its registry
  docker buildx imagetools inspect "$1" 2>/dev/null | sed -n 's/^Digest:[[:space:]]*//p' | head -n 1
}

if [ "$DRY_RUN" = true ]; then
  echo "Dry run: nothing pushed."
  exit 0
fi

if [ -z "$REGISTRY" ]; then
  command -v aws >/dev/null 2>&1 || die "the AWS CLI is required for the ECR target (or pass --registry)."
  REGION="${REGION:-${AWS_REGION:-$(aws configure get region || true)}}"
  [ -n "$REGION" ] || die "no region: pass --region, set AWS_REGION or configure a default region."
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

  if ! aws ecr describe-repositories --region "$REGION" --repository-names "$REPOSITORY" >/dev/null 2>&1; then
    aws ecr create-repository --region "$REGION" --repository-name "$REPOSITORY" \
      --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true >/dev/null
    echo "Created ECR repository ${REPOSITORY} (immutable tags, scan on push)."
  fi
  # The registry password goes through a pipe, never through argv or the terminal.
  aws ecr get-login-password --region "$REGION" |
    docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
fi

TARGET_REPO="${REGISTRY}/${REPOSITORY}"
TARGET="${TARGET_REPO}:${VERSION}"
docker tag "$SOURCE" "$TARGET"
echo "Pushing ${TARGET}"
if ! docker push --quiet "$TARGET" >/dev/null; then
  # ECR tags are immutable: the push fails when the tag already exists. Accept
  # that only when ECR confirms the tag is there, and say which image it is.
  if [ -n "${ACCOUNT_ID:-}" ] && STORED_DIGEST="$(aws ecr describe-images --region "$REGION" \
    --repository-name "$REPOSITORY" --image-ids imageTag="$VERSION" \
    --query 'imageDetails[0].imageDigest' --output text 2>/dev/null)" && [[ "$STORED_DIGEST" == sha256:* ]]; then
    [ "$STORED_DIGEST" = "$EXPECTED_PUSHED" ] ||
      die "tag ${VERSION} already exists in ${TARGET_REPO} as ${STORED_DIGEST}, which is not the verified ${PLATFORM} manifest ${EXPECTED_PUSHED}."
    echo "Tag ${VERSION} already exists in ${TARGET_REPO} and is the verified ${PLATFORM} manifest."
    echo ""
    echo "image_uri = \"${TARGET_REPO}@${STORED_DIGEST}\""
    exit 0
  fi
  die "could not push ${TARGET}."
fi

DIGEST="$(registry_digest "$TARGET")"
[ -n "$DIGEST" ] || die "pushed ${TARGET} but could not read its digest from the registry."
[ "$DIGEST" = "$EXPECTED_PUSHED" ] ||
  die "the registry holds ${TARGET} as ${DIGEST}, not the verified ${PLATFORM} manifest ${EXPECTED_PUSHED}."

echo ""
echo "Mirrored ${SOURCE} to ${TARGET_REPO}. Pass it to the app in deploy/terraform.tfvars:"
echo ""
echo "image_uri = \"${TARGET_REPO}@${DIGEST}\""

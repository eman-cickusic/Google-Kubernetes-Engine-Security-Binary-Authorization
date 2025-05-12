#!/bin/bash
# attest-image.sh - Script to attest a container image

# Default values
ATTESTOR="manually-verified"
ATTESTOR_NAME="Manual Attestor"
NOTE_ID="Human-Attestor-Note"
NOTE_DESC="Human Attestation Note Demo"
IMAGE_PATH=""
IMAGE_TAG="latest"

# Parse command line arguments
while getopts "a:n:i:t:p:" opt; do
  case $opt in
    a) ATTESTOR="$OPTARG" ;;
    n) NOTE_ID="$OPTARG" ;;
    i) IMAGE_PATH="$OPTARG" ;;
    t) IMAGE_TAG="$OPTARG" ;;
    p) PROJECT_ID="$OPTARG" ;;
    \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
  esac
done

# Check if image path was provided
if [ -z "$IMAGE_PATH" ]; then
  echo "Error: Image path is required. Use -i option."
  echo "Usage: $0 -i IMAGE_PATH [-a ATTESTOR] [-n NOTE_ID] [-t IMAGE_TAG] [-p PROJECT_ID]"
  exit 1
fi

# If project ID is not provided, use the default from gcloud config
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(gcloud config get-value project)
  if [ -z "$PROJECT_ID" ]; then
    echo "No project specified. Please specify a project with -p or set a default project with:"
    echo "gcloud config set project PROJECT_ID"
    exit 1
  fi
fi

# Get user email
ATTESTOR_EMAIL="$(gcloud config get-value core/account)"

# Set file paths
NOTE_PAYLOAD_PATH="note_payload.json"
PGP_PUB_KEY="generated-key.pgp"
GENERATED_PAYLOAD="generated_payload.json"
GENERATED_SIGNATURE="generated_signature.pgp"

echo "====== Attesting Container Image ======"
echo "Attestor: $ATTESTOR"
echo "Note ID: $NOTE_ID"
echo "Image: $IMAGE_PATH:$IMAGE_TAG"
echo "Project ID: $PROJECT_ID"

# Step 1: Create attestation note
echo "Creating attestation note..."
cat > ${NOTE_PAYLOAD_PATH} << EOF
{
  "name": "projects/${PROJECT_ID}/notes/${NOTE_ID}",
  "attestation_authority": {
    "hint": {
      "human_readable_name": "${NOTE_DESC}"
    }
  }
}
EOF

# Submit note to Container Analysis API
echo "Submitting note to Container Analysis API..."
curl -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    --data-binary @${NOTE_PAYLOAD_PATH} \
    "https://containeranalysis.googleapis.com/v1beta1/projects/${PROJECT_ID}/notes/?noteId=${NOTE_ID}"

# Step 2: Create PGP key
echo "Creating PGP key for signing..."
gpg --list-keys ${ATTESTOR_EMAIL} > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "PGP key not found, generating new key..."
    gpg --batch --passphrase "" --quick-generate-key --yes ${ATTESTOR_EMAIL}
fi

# Export public PGP key
echo "Exporting public PGP key..."
gpg --armor --export "${ATTESTOR_EMAIL}" > ${PGP_PUB_KEY}

# Step 3: Register attestor
echo "Registering attestor with Binary Authorization..."
gcloud --project="${PROJECT_ID}" \
    beta container binauthz attestors create "${ATTESTOR}" \
    --attestation-authority-note="${NOTE_ID}" \
    --attestation-authority-note-project="${PROJECT_ID}" \
    2>/dev/null || echo "Attestor already exists, continuing..."

# Add PGP key to attestor
echo "Adding PGP key to attestor..."
gcloud --project="${PROJECT_ID}" \
    beta container binauthz attestors public-keys add \
    --attestor="${ATTESTOR}" \
    --pgp-public-key-file="${PGP_PUB_KEY}" \
    2>/dev/null || echo "PGP key already added, continuing..."

# Step 4: Get image digest
echo "Getting image digest..."
FULL_IMAGE_PATH="gcr.io/${PROJECT_ID}/${IMAGE_PATH}"
if [ "${IMAGE_PATH}" == "gcr.io/"* ]; then
    FULL_IMAGE_PATH="${IMAGE_PATH}"
fi

# Ensure image exists
echo "Checking image exists..."
IMAGE_DIGEST=$(gcloud container images list-tags --format='get(digest)' ${FULL_IMAGE_PATH} 2>/dev/null | head -1)
if [ -z "$IMAGE_DIGEST" ]; then
    echo "Error: Image ${FULL_IMAGE_PATH}:${IMAGE_TAG} not found"
    exit 1
fi

echo "Image digest: ${IMAGE_DIGEST}"

# Step 5: Create signature payload
echo "Creating signature payload..."
gcloud beta container binauthz create-signature-payload \
    --artifact-url="${FULL_IMAGE_PATH}@${IMAGE_DIGEST}" > ${GENERATED_PAYLOAD}

# Step 6: Sign the payload
echo "Signing payload..."
PGP_FINGERPRINT="$(gpg --list-keys ${ATTESTOR_EMAIL} | head -2 | tail -1 | awk '{print $1}')"
gpg --local-user "${ATTESTOR_EMAIL}" \
    --armor \
    --output ${GENERATED_SIGNATURE} \
    --sign ${GENERATED_PAYLOAD}

# Step 7: Create attestation
echo "Creating attestation..."
gcloud beta container binauthz attestations create \
    --artifact-url="${FULL_IMAGE_PATH}@${IMAGE_DIGEST}" \
    --attestor="projects/${PROJECT_ID}/attestors/${ATTESTOR}" \
    --signature-file=${GENERATED_SIGNATURE} \
    --public-key-id="${PGP_FINGERPRINT}"

# Step 8: Verify attestation
echo "Verifying attestation..."
gcloud beta container binauthz attestations list \
    --attestor="projects/${PROJECT_ID}/attestors/${ATTESTOR}" \
    --artifact-url="${FULL_IMAGE_PATH}@${IMAGE_DIGEST}"

echo "====== Attestation Complete ======"
echo "Image: ${FULL_IMAGE_PATH}@${IMAGE_DIGEST}"
echo "Attestor: projects/${PROJECT_ID}/attestors/${ATTESTOR}"
echo ""
echo "To use this image in a pod, use the following format with the digest:"
echo ""
echo "apiVersion: v1"
echo "kind: Pod"
echo "metadata:"
echo "  name: attested-pod"
echo "spec:"
echo "  containers:"
echo "  - name: attested-container"
echo "    image: \"${FULL_IMAGE_PATH}@${IMAGE_DIGEST}\""
echo "    ports:"
echo "    - containerPort: 80"

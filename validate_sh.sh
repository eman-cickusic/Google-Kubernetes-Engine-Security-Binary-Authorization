#!/bin/bash
# validate.sh - Script to validate Binary Authorization setup

# Default values
CLUSTER_NAME="my-cluster-1"

# Parse command line arguments
while getopts "c:z:p:" opt; do
  case $opt in
    c) CLUSTER_NAME="$OPTARG" ;;
    z) ZONE="$OPTARG" ;;
    p) PROJECT_ID="$OPTARG" ;;
    \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
  esac
done

# If zone is not provided, use the default from gcloud config
if [ -z "$ZONE" ]; then
  ZONE=$(gcloud config get-value compute/zone)
  if [ -z "$ZONE" ]; then
    echo "No zone specified. Please specify a zone with -z or set a default zone with:"
    echo "gcloud config set compute/zone ZONE"
    exit 1
  fi
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

echo "====== Validating Binary Authorization Setup ======"
echo "Cluster name: $CLUSTER_NAME"
echo "Zone: $ZONE"
echo "Project ID: $PROJECT_ID"

# Validate Binary Authorization API
echo "Checking Binary Authorization API..."
if gcloud beta container binauthz policy export > /dev/null 2>&1; then
    echo "Validation Passed: the BinAuthZ policy was available"
    BINAUTHZ_OK=true
else
    echo "Validation Failed: the BinAuthZ policy was NOT available"
    BINAUTHZ_OK=false
fi

# Validate Container Analysis API
echo "Checking Container Analysis API..."
NOTE_ID="test-validation-note-$(date +%s)"
NOTE_PAYLOAD="{\"name\": \"projects/${PROJECT_ID}/notes/${NOTE_ID}\", \"attestation_authority\": {\"hint\": {\"human_readable_name\": \"Test Validation Note\"}}}"

if echo "$NOTE_PAYLOAD" | curl -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    --data @- \
    "https://containeranalysis.googleapis.com/v1beta1/projects/${PROJECT_ID}/notes/?noteId=${NOTE_ID}" > /dev/null 2>&1; then
    
    # Clean up test note
    curl -X DELETE \
        -H "Authorization: Bearer $(gcloud auth print-access-token)" \
        "https://containeranalysis.googleapis.com/v1beta1/projects/${PROJECT_ID}/notes/${NOTE_ID}" > /dev/null 2>&1
    
    echo "Validation Passed: the Container Analysis API was available"
    CONTAINER_ANALYSIS_OK=true
else
    echo "Validation Failed: the Container Analysis API was NOT available"
    CONTAINER_ANALYSIS_OK=false
fi

# Validate cluster has Binary Authorization enabled
echo "Checking if cluster has Binary Authorization enabled..."
CLUSTER_BINAUTHZ=$(gcloud container clusters describe ${CLUSTER_NAME} --zone ${ZONE} --format="value(binaryAuthorization.enabled)")

if [ "$CLUSTER_BINAUTHZ" == "True" ] || [ "$CLUSTER_BINAUTHZ" == "true" ]; then
    echo "Validation Passed: Binary Authorization is enabled on the cluster"
    CLUSTER_BINAUTHZ_OK=true
else
    echo "Validation Failed: Binary Authorization is NOT enabled on the cluster"
    CLUSTER_BINAUTHZ_OK=false
fi

# Overall validation result
echo ""
echo "====== Validation Summary ======"
if [ "$BINAUTHZ_OK" == "true" ] && [ "$CONTAINER_ANALYSIS_OK" == "true" ] && [ "$CLUSTER_BINAUTHZ_OK" == "true" ]; then
    echo "All validations passed! Your Binary Authorization setup is ready."
else
    echo "Some validations failed. Please check the errors above."
fi

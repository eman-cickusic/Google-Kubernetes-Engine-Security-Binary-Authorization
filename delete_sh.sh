#!/bin/bash
# delete.sh - Script to clean up GKE cluster and Binary Authorization resources

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

echo "====== Cleaning up resources ======"
echo "Cluster name: $CLUSTER_NAME"
echo "Zone: $ZONE"
echo "Project ID: $PROJECT_ID"

# Delete GKE cluster
echo "Deleting cluster..."
gcloud container clusters delete ${CLUSTER_NAME} --zone ${ZONE} --quiet

echo "Note: Cluster delete command is being run asynchronously and will take a few moments to be removed."
echo "Use the Cloud Console UI or gcloud container clusters list command to track the progress if desired."
echo "Wait until cluster gets removed."

echo "====== Additional cleanup commands ======"
echo "To delete container images from GCR:"
echo "gcloud container images delete \"gcr.io/\${PROJECT_ID}/nginx@\${IMAGE_DIGEST}\" --force-delete-tags"
echo ""
echo "To delete attestors:"
echo "gcloud --project=\"\${PROJECT_ID}\" beta container binauthz attestors delete \"\${ATTESTOR}\""
echo ""
echo "To delete Container Analysis notes:"
echo "curl -X DELETE -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \"https://containeranalysis.googleapis.com/v1beta1/projects/\${PROJECT_ID}/notes/\${NOTE_ID}\""

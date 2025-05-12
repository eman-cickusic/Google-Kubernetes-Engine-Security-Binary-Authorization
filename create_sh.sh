#!/bin/bash
# create.sh - Script to create a GKE cluster with Binary Authorization enabled

# Default values
CLUSTER_NAME="my-cluster-1"
MACHINE_TYPE="n1-standard-1"
NUM_NODES=2

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

echo "====== Creating GKE cluster with Binary Authorization ======"
echo "Cluster name: $CLUSTER_NAME"
echo "Zone: $ZONE"
echo "Project ID: $PROJECT_ID"

# Enable necessary APIs
echo "Enabling required APIs..."
gcloud services enable container.googleapis.com
gcloud services enable containerregistry.googleapis.com
gcloud services enable containeranalysis.googleapis.com
gcloud services enable binaryauthorization.googleapis.com

# Get default cluster version
echo "Getting default cluster version..."
defaultClusterVersion=$(gcloud container get-server-config --zone=${ZONE} --format="value(defaultClusterVersion)")
echo "Using GKE version: $defaultClusterVersion"

# Create GKE cluster with Binary Authorization
echo "Creating GKE cluster..."
gcloud container clusters create ${CLUSTER_NAME} \
  --zone ${ZONE} \
  --enable-binauthz \
  --machine-type ${MACHINE_TYPE} \
  --num-nodes ${NUM_NODES} \
  --cluster-version ${defaultClusterVersion}

# Configure kubectl to connect to the cluster
echo "Configuring kubectl..."
gcloud container clusters get-credentials ${CLUSTER_NAME} --zone ${ZONE}

echo "====== Cluster creation complete ======"
echo "GKE cluster ${CLUSTER_NAME} with Binary Authorization has been created."
kubectl get nodes

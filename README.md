# Google Kubernetes Engine Security Binary Authorization

This repository demonstrates how to implement Binary Authorization in Google Kubernetes Engine (GKE) for enhanced container security. Binary Authorization is a deploy-time security control that ensures only trusted container images are deployed to your GKE clusters.

## Overview

One of the key security concerns for running Kubernetes clusters is knowing what container images are running inside each pod and being able to account for their origin. Binary Authorization allows you to:

- Enforce where images originate from (safe origin)
- Ensure all validation steps were completed for every container build and deployment (consistency and validation)
- Verify containers were not modified after their provenance was proven (integrity)

Not enforcing where images originate from presents several risks:
- A malicious actor with compromised cluster privileges may launch containers from unknown sources
- Authorized users with pod creation permissions may accidentally or maliciously run undesired containers
- Authorized users may accidentally or maliciously overwrite container images with modified code

## Video  

https://youtu.be/2evJMWa7Z-Q


## Architecture 

Binary Authorization and Container Analysis APIs are based on the open-source projects Grafeas and Kritis:

- **Grafeas**: Defines an API spec for managing metadata about software resources like container images
- **Kritis**: Defines an API for preventing deployments unless artifacts conform to policy and have necessary attestations

In a typical container deployment pipeline:
1. Source code is stored in source control
2. Upon committing changes, containers are built and tested
3. When build and test steps complete, container artifacts are placed in a registry
4. When deployment is submitted to Kubernetes API, the container runtime pulls the image and runs it

Binary Authorization adds attestation steps to this pipeline, where each step in the process can "attest" that requirements were met.

## Prerequisites

- Google Cloud Platform account with a project
- gcloud CLI installed and configured
- kubectl installed and configured
- Docker installed (for creating images)

## Implementation Steps

### 1. Create a GKE Cluster with Binary Authorization

```bash
# Enable necessary APIs
gcloud services enable container.googleapis.com
gcloud services enable containerregistry.googleapis.com
gcloud services enable containeranalysis.googleapis.com
gcloud services enable binaryauthorization.googleapis.com

# Create GKE cluster with Binary Authorization enabled
gcloud container clusters create my-cluster-1 \
  --zone [ZONE] \
  --enable-binauthz \
  --machine-type n1-standard-1 \
  --num-nodes 2

# Get cluster credentials
gcloud container clusters get-credentials my-cluster-1 --zone [ZONE]
```

### 2. Configure Binary Authorization Policy

#### Default Project Policy
1. Navigate to Security > Binary Authorization in Google Cloud Console
2. Click "Edit Policy"
3. Change the Default rule to "Disallow all images"
4. Add cluster-specific rules to allow images for your cluster

#### Cluster-Specific Policy
1. In "Additional settings for GKE and Anthos deployments", click "Create Specific Rules"
2. Select "GKE Cluster" from the dropdown
3. Add a specific rule for your cluster: `[ZONE].my-cluster-1`
4. Set the rule to "Allow all images" initially
5. Click "Save Policy"

### 3. Create a Private GCR Image

```bash
# Pull nginx image
docker pull nginx:latest

# Configure docker with GCP credentials
gcloud auth configure-docker

# Tag and push to your project's GCR
PROJECT_ID=$(gcloud config get-value project)
docker tag nginx "gcr.io/${PROJECT_ID}/nginx:latest"
docker push "gcr.io/${PROJECT_ID}/nginx:latest"

# List images in your GCR
gcloud container images list-tags "gcr.io/${PROJECT_ID}/nginx"
```

### 4. Test Binary Authorization Enforcement

#### Test with "Allow All Images" Policy
```bash
# Create a simple nginx pod
cat << EOF | kubectl create -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: "gcr.io/${PROJECT_ID}/nginx:latest"
    ports:
    - containerPort: 80
EOF

# Verify pod is running
kubectl get pods

# Delete the pod
kubectl delete pod nginx
```

#### Change Policy to "Disallow All Images" for Cluster
1. Edit the Binary Authorization policy
2. Modify your cluster-specific rule to "Disallow all images"
3. Save the policy
4. Wait 30 seconds for the policy to take effect

```bash
# Try to create the same pod (this should fail)
cat << EOF | kubectl create -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: "gcr.io/${PROJECT_ID}/nginx:latest"
    ports:
    - containerPort: 80
EOF
```

### 5. Configure Registry Allowlisting

1. Edit the Binary Authorization policy
2. Add an image path pattern under "Custom exemption rules": `gcr.io/${PROJECT_ID}/nginx*`
3. Save the policy
4. Test by creating the nginx pod again (should now succeed)

### 6. Implement Attestation Enforcement

#### Set Up Attestation Authority
```bash
# Set variables
ATTESTOR="manually-verified"
ATTESTOR_NAME="Manual Attestor"
ATTESTOR_EMAIL="$(gcloud config get-value core/account)"
NOTE_ID="Human-Attestor-Note"
NOTE_DESC="Human Attestation Note Demo"
NOTE_PAYLOAD_PATH="note_payload.json"
IAM_REQUEST_JSON="iam_request.json"

# Create attestation note payload
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

# Submit attestation note to Container Analysis API
curl -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)"  \
    --data-binary @${NOTE_PAYLOAD_PATH}  \
    "https://containeranalysis.googleapis.com/v1beta1/projects/${PROJECT_ID}/notes/?noteId=${NOTE_ID}"
```

#### Create PGP Signing Key
```bash
# Install tools for random number generation
sudo apt-get install rng-tools
sudo rngd -r /dev/urandom

# Set variable for PGP key
PGP_PUB_KEY="generated-key.pgp"

# Generate PGP key
gpg --quick-generate-key --yes ${ATTESTOR_EMAIL}

# Export public PGP key
gpg --armor --export "${ATTESTOR_EMAIL}" > ${PGP_PUB_KEY}
```

#### Register Attestor with Binary Authorization
```bash
# Create attestor
gcloud --project="${PROJECT_ID}" \
    beta container binauthz attestors create "${ATTESTOR}" \
    --attestation-authority-note="${NOTE_ID}" \
    --attestation-authority-note-project="${PROJECT_ID}"

# Add PGP key to attestor
gcloud --project="${PROJECT_ID}" \
    beta container binauthz attestors public-keys add \
    --attestor="${ATTESTOR}" \
    --pgp-public-key-file="${PGP_PUB_KEY}"

# List created attestor
gcloud --project="${PROJECT_ID}" \
    beta container binauthz attestors list
```

#### Sign a Container Image
```bash
# Set variables
GENERATED_PAYLOAD="generated_payload.json"
GENERATED_SIGNATURE="generated_signature.pgp"
PGP_FINGERPRINT="$(gpg --list-keys ${ATTESTOR_EMAIL} | head -2 | tail -1 | awk '{print $1}')"

# Get container image digest
IMAGE_PATH="gcr.io/${PROJECT_ID}/nginx"
IMAGE_DIGEST="$(gcloud container images list-tags --format='get(digest)' $IMAGE_PATH | head -1)"

# Create signature payload
gcloud beta container binauthz create-signature-payload \
    --artifact-url="${IMAGE_PATH}@${IMAGE_DIGEST}" > ${GENERATED_PAYLOAD}

# Sign the payload
gpg --local-user "${ATTESTOR_EMAIL}" \
    --armor \
    --output ${GENERATED_SIGNATURE} \
    --sign ${GENERATED_PAYLOAD}

# Create attestation
gcloud beta container binauthz attestations create \
    --artifact-url="${IMAGE_PATH}@${IMAGE_DIGEST}" \
    --attestor="projects/${PROJECT_ID}/attestors/${ATTESTOR}" \
    --signature-file=${GENERATED_SIGNATURE} \
    --public-key-id="${PGP_FINGERPRINT}"

# View created attestation
gcloud beta container binauthz attestations list \
    --attestor="projects/${PROJECT_ID}/attestors/${ATTESTOR}"
```

### 7. Enable Attestation Enforcement

1. Edit the Binary Authorization policy
2. Change your cluster-specific rule to "Require attestations"
3. Add your attestor: `projects/${PROJECT_ID}/attestors/${ATTESTOR}`
4. Save the policy and wait 30 seconds

```bash
# Deploy pod with attested image (specify digest)
cat << EOF | kubectl create -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: "${IMAGE_PATH}@${IMAGE_DIGEST}"
    ports:
    - containerPort: 80
EOF
```

### 8. Emergency "Break Glass" Feature

In emergency situations, you can use the "break glass" annotation to bypass Binary Authorization:

```bash
# Deploy with break-glass annotation
cat << EOF | kubectl create -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-alpha
  annotations:
    alpha.image-policy.k8s.io/break-glass: "true"
spec:
  containers:
  - name: nginx
    image: "nginx:latest"
    ports:
    - containerPort: 80
EOF
```

Monitor break-glass usage with Stackdriver logs:
```
resource.type="k8s_cluster" protoPayload.request.metadata.annotations."alpha.image-policy.k8s.io/break-glass"="true"
```

## Cleanup

```bash
# Delete cluster
gcloud container clusters delete my-cluster-1 --zone [ZONE]

# Delete container image
gcloud container images delete "${IMAGE_PATH}@${IMAGE_DIGEST}" --force-delete-tags

# Delete attestor
gcloud --project="${PROJECT_ID}" \
    beta container binauthz attestors delete "${ATTESTOR}"

# Delete Container Analysis note
curl -X DELETE \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://containeranalysis.googleapis.com/v1beta1/projects/${PROJECT_ID}/notes/${NOTE_ID}"
```

## Troubleshooting

1. If policy changes don't immediately take effect, wait 30 seconds before retrying
2. Check cluster status with `gcloud container clusters list`
3. If using additional features like `--enable-network-policy`, you may need to allowlist additional registries
4. If encountering quota errors, increase your project quotas

## Additional Resources

1. [Google Cloud Quotas](https://cloud.google.com/compute/quotas)
2. [Sign up for Google Cloud](https://cloud.google.com/free/)
3. [Google Cloud Shell](https://cloud.google.com/shell/docs)
4. [Binary Authorization in GKE](https://cloud.google.com/binary-authorization/docs/overview)
5. [Container Analysis notes](https://cloud.google.com/container-analysis/docs/concepts-notes)
6. [Kubernetes Admission Controller](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)

CLUSTER_NAME="baptiste-billion"
GCP_PROJECT="solo.io"
REGION="europe-west1"
ZONE="europe-west1-b"
NUM_NODES=100

gcloud config set project $GCP_PROJECT

# CREATE
gcloud beta container \
  --project ${GCP_PROJECT} \
  clusters create ${CLUSTER_NAME} \
  --zone ${ZONE} \
  --cluster-version "1.23.7-gke.1400" \
  --release-channel "regular" \
  --no-enable-basic-auth \
  --machine-type "e2-standard-16" \
  --disk-type "pd-standard" \
  --disk-size "20" \
  --metadata disable-legacy-endpoints=true \
  --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" \
  --num-nodes ${NUM_NODES} \
  --logging=SYSTEM \
  --monitoring=SYSTEM \
  --enable-ip-alias \
  --network "projects/${GCP_PROJECT}/global/networks/default" \
  --subnetwork "projects/${GCP_PROJECT}/regions/${REGION}/subnetworks/default" \
  --default-max-pods-per-node "40" \
  --no-enable-master-authorized-networks \
  --addons HorizontalPodAutoscaling,HttpLoadBalancing \
  --enable-autoupgrade \
  --enable-autorepair \
  --max-surge-upgrade 1 \
  --max-unavailable-upgrade 0 \
  --cluster-ipv4-cidr=/16 \
  --node-locations ${ZONE} \
  --enable-dataplane-v2


# RENAME
k config rename-context gke_${GCP_PROJECT}_${ZONE}_${CLUSTER_NAME} ${CLUSTER_NAME}

# DELETE
# CAUTION!!!!!!!!!!
(
  gcloud container clusters delete ${CLUSTER_NAME}
  kubectl config delete-context ${CLUSTER_NAME}
)

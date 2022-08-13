##################
# GKE cluster
##################
# see gke.sh


##################
# Gloo deployment
##################
export GLOO_VERSION=1.11.28

helm upgrade -i gloo glooe/gloo-ee --namespace gloo-system --version ${GLOO_VERSION} \
  --create-namespace --set-string license_key="$LICENSE_KEY" -f values.yaml


#######################
# GCP LB configuration
# https://docs.solo.io/gloo-edge/latest/guides/integrations/google_cloud/#https-load-balancer
#######################

# GOOGLE GLOBAL LB
cat <<EOF
                                                                   (Health checks) \
                                                                                     \
(IP Address) --> (Forwarding rule) -->  (target HTTP proxy) --> (URL maps) --> (backend service) --> (NEG) --> (pods)
EOF

# Fetch the NEG
# find the network tags used by our cluster
NETWORK_TAGS=$(gcloud compute instances describe \
    $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') \
    --zone=$ZONE --format="value(tags.items[0])")

# FIREWALL RULE
# gcloud compute firewall-rules create baptiste-billion-http-fw-allow-health-check-and-proxy \
gcloud compute firewall-rules update baptiste-billion-http-fw-allow-health-check-and-proxy \
   --source-ranges=0.0.0.0/0 \
   --rules=tcp:8080 \
   --target-tags ${NETWORK_TAGS}

# Health Check
gcloud beta compute health-checks create http envoy-http-global-hc --project=solo-test-236622 --port=8080 --request-path=/envoy-hc --proxy-header=NONE --global --no-enable-logging --description=HTTP\ HC\ targetting\ the\ Envoy\ HC\ filter --check-interval=5 --timeout=5 --unhealthy-threshold=2 --healthy-threshold=2

# IP ADDRESS
gcloud compute addresses create baptiste-billion-ext-ip --project=solo-test-236622 --description=temp\ IP\ addr\ for\ bench\ purpose --global
# fetch it
gcloud compute addresses describe baptiste-billion-ext-ip --global --format json | jq '.address'

# Backend Service
gcloud compute backend-services create baptiste-billion-backend-service \
    --protocol=HTTP \
    --health-checks envoy-http-global-hc \
    --global

# URL Maps
# URL map to route HTTP(S) requests to backend services
gcloud compute url-maps create baptiste-billion-http-url-map \
    --default-service baptiste-billion-backend-service \
    --global

# Target HTTP Proxy
# Target proxies terminate connections from the client and creates new connections to the backends.
gcloud compute target-http-proxies create baptiste-billion-http-target-proxy \
    --url-map=baptiste-billion-http-url-map \
    --global

# Forwarding Rule
# A forwarding rule and its corresponding IP address represent the frontend configuration of a Google Cloud load balancer.
gcloud compute forwarding-rules create baptiste-billion-fwd-rule \
    --address=baptiste-billion-ext-ip \
    --global \
    --target-http-proxy baptiste-billion-http-target-proxy \
    --ports=80

# Attach the NEG to the Backend Svc
gcloud compute backend-services add-backend baptiste-billion-backend-service \
    --network-endpoint-group=baptiste-billion-neg \
    --balancing-mode RATE \
    --max-rate-per-endpoint 5 \
    --network-endpoint-group-zone europe-west1-b \
    --global



#######################################
# BACKEND: Envoy with direct-response
#######################################
cd direct-response-backend
docker build -f Dockerfile-frontenvoy -t pileenretard/envoy-direct-response:1.3 --rm .
docker push pileenretard/envoy-direct-response:1.3

k create deploy envoy-direct-resp --image pileenretard/envoy-direct-response:1.3 --replicas 3
k expose deploy/envoy-direct-resp --target-port 10000 --port 10000



###################
# GLOO ROUTING
###################
k apply -f - <<EOF
apiVersion: gloo.solo.io/v1
kind: Upstream
metadata:
  name: envoy-direct-resp
  namespace: gloo-system
spec:
  kube:
    serviceName: envoy-direct-resp
    serviceNamespace: default
    servicePort: 10000
  circuitBreakers:
    maxConnections: 7512
    maxPendingRequests: 10000
    maxRequests: 4294967295
    maxRetries: 30
  healthChecks:
    - healthyThreshold: 1
      httpHealthCheck:
        path: /
      interval: 3s
      noTrafficInterval: 2s
      timeout: 1s
      unhealthyThreshold: 2
      reuseConnection: true
  ignoreHealthOnHostRemoval: true
  connectionConfig:
    maxRequestsPerConnection: 0
    connectTimeout: 2s
    commonHttpProtocolOptions:
      idleTimeout: 4s
EOF


# api key
glooctl create secret apikey testing-apikey \
    --apikey abc \
    --apikey-labels api-key-role=testing

kubectl apply -f - <<EOF
apiVersion: enterprise.gloo.solo.io/v1
kind: AuthConfig
metadata:
  name: api-key-ac
  namespace: gloo-system
spec:
  configs:
    - apiKeyAuth:
        labelSelector:
          api-key-role: testing
        headerName: api-key
EOF

# VirtualService
k apply -f - <<EOF
apiVersion: gateway.solo.io/v1
kind: VirtualService
metadata:
  name: httpbin
  namespace: gloo-system
spec:
  virtualHost:
    domains:
    - '*'
    routes:
    - matchers:
      - prefix: /envoy-hc
      options:
        extauth:
          disable: true
      directResponseAction:
        status: 200
    - matchers:
      - prefix: /
      options:
        retries:
          numRetries: 2
          perTryTimeout: 2s
          retryOn: 5xx,gateway-error,reset,connect-failure
      routeAction:
        single:
          upstream:
            name: envoy-direct-resp
            namespace: gloo-system
    options:
      extauth:
        configRef:
          name: api-key-ac
          namespace: gloo-system
EOF



########
# HEY
########
k apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hey
  labels:
    app: hey
spec:
  selector:
    matchLabels:
      octopusexport: OctopusExport
  replicas: 1
  strategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: hey
        octopusexport: OctopusExport
    spec:
      containers:
        - name: hey
          image: williamyeh/hey
          args:
          - "-z"
          - "60m"
          - "-t"
          - "2"
          - "-c"
          - "100"
          - "-H"
          - "api-key: abc"
          - "http://34.160.63.119/"
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values:
                        - hey
                topologyKey: kubernetes.io/hostname
EOF



##################
# PROM & GRAFANA
##################
# prom
kubectl -n gloo-system port-forward svc/glooe-prometheus-server 8001:80 &

# grafana
kubectl -n gloo-system port-forward svc/glooe-grafana 3000:80 &
# pick the "envoy-direct-resp_gloo-system" Upstream in "All Upstreams"



########################
# SCALING EVERYTHING UP
# BENCHMARKING
########################

# scale up k8s nodes
gcloud container clusters resize baptiste-billion --num-nodes 100

# extauth
kgloo scale deploy/extauth --replicas 150

# gw-proxy
k -n gloo-system scale deploy/gateway-proxy --replicas 90

# direct-response
k scale deploy/envoy-direct-resp --replicas 350


# Hey
k scale deploy/hey --replicas 40


###########
# UPGRADE
###########
export GLOO_VERSION=1.11.30
helm upgrade gloo glooe/gloo-ee --namespace gloo-system --version ${GLOO_VERSION} \
  --create-namespace --set-string license_key="$LICENSE_KEY" -f values-prod-gke-apikey-scaled-up.yaml



#######################
# RESET Envoy counters
#######################
kgloo get pods -l "gloo=gateway-proxy" -o name | xargs -P 4 -I{} sh -c 'kubectl -n gloo-system exec {} -- wget --post-data "" -O /dev/null -q 127.0.0.1:19000/reset_counters'



#############
# scale down
#############
gcloud container clusters resize ${CLUSTER_NAME} --num-nodes=0

k scale deploy/envoy-direct-resp --replicas 3

k scale deploy/hey --replicas 0

glooctl uninstall --all



#############
# Cleanup
#############
k delete deploy hey
k delete deploy/envoy-direct-resp
k delete svc/envoy-direct-resp
glooctl uninstall --all



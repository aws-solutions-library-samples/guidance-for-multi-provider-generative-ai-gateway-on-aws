# Guidance: running the gateway on Amazon EKS

> [!IMPORTANT]
> This page is guidance, not a tested or supported deployment. The Guidance deploys and tests the gateway on
> Amazon ECS (`terraform/app`) only. The snippets below are illustrative excerpts and have not been tested; adapt
> and test them in your own environment before use.

The gateway's state lives in the foundation stack (`terraform/foundation`): VPC, RDS PostgreSQL, Redis, Secrets
Manager and the config bucket. The ECS app stack is one consumer of it. An EKS version replaces the app stack and
leaves the foundation as it is: it runs the same official LiteLLM image against the same data stores and secrets.

## The interface: foundation outputs

Everything an EKS app stack needs comes from the foundation outputs:

| Output | Used for |
| --- | --- |
| `vpc_id`, `private_subnet_ids`, `vpc_cidr` | Where the cluster's nodes run |
| `public_subnet_ids` | Public subnets, when the foundation was deployed with `public_mode = true` |
| `redis_endpoint`, `redis_port` | `REDIS_HOST`, `REDIS_PORT` |
| `database_url_secret_arn`, `master_key_secret_arn`, `salt_key_secret_arn`, `redis_auth_secret_arn`, `ui_password_secret_arn` | The values of the Kubernetes Secret |
| `kms_key_arn` | Encryption of anything the EKS stack creates, when a customer key is used. Without one, the output is null and absent from `terraform output -json`, so `jq -r .kms_key_arn` prints `null` |

The config's trusted proxy range (`trusted_proxy_ranges`) is the address range of the load balancer or ingress in
front of the pods: `vpc_cidr` when it runs in the foundation's VPC, the cluster VPC's range otherwise.

### Deploy only the foundation

`deploy/deploy.sh` always applies the ECS app stack as well, so an EKS stack deploys the foundation on its own,
with the same state bucket and key as `deploy.sh`. The state bucket must exist; see
[Terraform state](../../docs/deployment.md#terraform-state). From the repository root:

```bash
export AWS_REGION=<region>
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
terraform -chdir=terraform/foundation init -reconfigure \
  -backend-config="bucket=litellm-gateway-tfstate-${ACCOUNT_ID}-${AWS_REGION}" \
  -backend-config="key=<deployment_name>/foundation.tfstate" \
  -backend-config="region=${AWS_REGION}" -backend-config="encrypt=true" -backend-config="use_lockfile=true"
terraform -chdir=terraform/foundation apply -var-file=../../deploy/terraform.tfvars

mkdir -p deploy/.generated
terraform -chdir=terraform/foundation output -json | jq 'with_entries(.value |= .value) | del(.db_endpoint)' \
  > deploy/.generated/<deployment_name>-foundation-outputs.tfvars.json
```

App-only inputs in `deploy/terraform.tfvars` print `Value for undeclared variable` warnings; that is expected.

### Network limits of the foundation

- **Primary CIDR only.** The foundation uses the VPC's primary IPv4 CIDR (`vpc_cidr`) for the interface-endpoint
  security group, the demo VPN and the default client range. Nodes or pods in a secondary CIDR (for example with
  custom networking) are not covered by these rules: keep them in the primary CIDR, or extend the rules yourself.
- **No subnet role tags.** The created subnets carry no `kubernetes.io/role/internal-elb` or
  `kubernetes.io/role/elb` tags. Tag them yourself, or name the subnets explicitly in your Ingress or Service
  annotations.
- **No outbound internet access.** With `disable_outbound_network_access`, the foundation creates only the
  interface endpoints the ECS stack needs. An EKS stack also needs endpoints such as `eks-auth` (Pod Identity),
  `ec2`, `eks`, `elasticloadbalancing`, and `autoscaling` for managed node groups, and an image it can pull:
  copy it with `deploy/mirror-image.sh` and use the printed URI in place of the `ghcr.io` image.

The only change to the foundation is its generic client input: `extra_data_ingress_security_group_ids` (or
`extra_data_ingress_cidrs` for a cluster in another, routed VPC) admits the cluster to RDS and Redis. With the
Amazon VPC CNI, pods use their node's security groups; EKS Auto Mode nodes and managed node groups without a custom
launch template use the cluster security group:

```bash
aws eks describe-cluster --name <cluster> \
  --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text
```

```hcl
# deploy/terraform.tfvars, then apply the foundation as above
extra_data_ingress_security_group_ids = ["sg-0123456789abcdef0"]
```

Every node and pod in that group can then open connections to the data stores (they still need the credentials).
To narrow it, admit a security group used only by the gateway's nodes, or security groups for pods.

## Building blocks and recommended choices

- **Image: the `tag@digest` from `terraform/app/container.tf`.** One pinned image for both runtimes; read it from
  the `image` line instead of copying it, so an upgrade there reaches the cluster too.
- **Container settings: mirror the `container` block in `terraform/app/container.tf`.** Same port (4000),
  environment and secret names, so both runtimes behave alike. Two differences are expected: the config is mounted
  from a ConfigMap (`--config`) instead of `LITELLM_CONFIG_BUCKET_NAME` and `LITELLM_CONFIG_BUCKET_OBJECT_KEY`, and
  `AWS_REGION` is set explicitly (ECS injects it).
- **Config: a ConfigMap rendered from `terraform/app/templates/config-base.yaml.tftpl`.** The template takes
  `trusted_proxy_ranges`, `request_log_bucket` and `region`, as in `terraform/app/config.tf`. Name the ConfigMap
  after the config's hash and set `LITELLM_CONFIG_SHA` to it, so a config change rolls the pods and each ReplicaSet
  keeps its own config. This avoids a dependency on the ECS app's config object and request-log bucket; the s3
  callbacks need a request-log bucket of the EKS stack.
- **Secrets: a Kubernetes Secret written from the Secrets Manager values.** Read the five values at deploy time
  and pass them to `kubectl` on stdin, not as command arguments; server-side apply avoids a second copy in the
  `last-applied-configuration` annotation. Restart the pods after you change a secret. Unlike on ECS, the values are
  then readable by anyone who may read Secrets in the namespace.
- **AWS access: EKS Pod Identity, with the statements of the ECS task role (`terraform/app/iam.tf`) the pods
  need:** `BedrockInference` and `BedrockGuardrails`; `WriteRequestLogs` (`s3:PutObject`) on the EKS stack's own
  request-log bucket; `DecryptConfigAndEncryptLogs` (`kms:Decrypt`, `kms:GenerateDataKey`) when a customer key
  encrypts that bucket; and `CrossAccountModels` (`sts:AssumeRole`) when `cross_account_role_arns` is used.
  `ReadConfig` is not needed, because the config comes from a ConfigMap. Pod Identity needs no per-cluster
  OIDC provider and no service-account annotation. It requires the EKS Pod Identity Agent (built into EKS Auto
  Mode) and does not apply to pods on AWS Fargate.
- **Schema migration: a Job before every rollout.** LiteLLM reports healthy on an unmigrated database, so health
  checks cannot gate a rollout. Run the image once with `DISABLE_SCHEMA_UPDATE=false` and `--skip_server_startup`,
  and apply the Deployment (which keeps `DISABLE_SCHEMA_UPDATE=true`) only after the Job completes. A Job's pod
  template cannot be changed, so name each Job after the image digest and config hash (or delete the previous Job
  first) and set `ttlSecondsAfterFinished`.
- **Probes: `/health/liveliness`, the ECS health-check path.** A liveness probe with ten 30-second misses (as the
  ECS container health check), so a busy pod is not restarted with its streams in flight; a readiness probe with
  the ALB target-group thresholds; a startup probe in place of the ECS start period.
- **Grace period: 120 s for LiteLLM after SIGTERM (`stop_timeout`), plus a short `preStop` pause.** The pause lets
  the endpoint removal propagate before shutdown; `terminationGracePeriodSeconds` covers both.
- **Security context.** `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, all capabilities
  dropped, and `automountServiceAccountToken: false` (LiteLLM does not call the Kubernetes API). Set
  `runAsNonRoot` only with an image that runs as a non-root user.

## What ECS provides that an EKS stack must add itself

| `terraform/app` on ECS | On EKS |
| --- | --- |
| Application Load Balancer with TLS, access logs and OIDC sign-in in front of the UI paths | An ingress or load balancer of your choice, with TLS and sign-in for the UI |
| AWS WAF in public mode | A web ACL on the load balancer you add |
| Migration, then rollout, in one apply; the deployment circuit breaker rolls back a failed rollout | Your own migration gate; a stalled rollout is not rolled back automatically |
| CloudWatch logs, alarms, dashboard and SNS notifications (`terraform/modules/observability`) | Log shipping, metrics and alarms of the cluster |
| CPU and memory target-tracking scaling, 2 to 20 tasks, sized against the database connection alarm | A HorizontalPodAutoscaler, a PodDisruptionBudget and limits sized for the database |
| Memory-aware recycling: a task whose memory stays at 90 % is replaced before it is stopped | No equivalent; a pod that reaches its memory limit is killed |
| Drain tuning: 120 s stop timeout matched to the target deregistration delay; `KEEPALIVE_TIMEOUT` above the 600 s ALB idle timeout | The same alignment between the grace period, the load balancer's deregistration delay and its idle timeout |

## Example snippets

Illustrative and untested. Placeholders are in angle brackets.

Pod Identity role and association (Terraform, AWS provider). Attach a policy with the `BedrockInference` and
`BedrockGuardrails` statements of `terraform/app/iam.tf`:

```hcl
resource "aws_iam_role" "litellm_pod" {
  name = "<name>-litellm-pod"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = { "aws:SourceAccount" = "<account-id>" }
        ArnEquals    = { "aws:SourceArn" = "arn:aws:eks:<region>:<account-id>:cluster/<cluster>" }
      }
    }]
  })
}

resource "aws_eks_pod_identity_association" "litellm" {
  cluster_name    = "<cluster>"
  namespace       = "litellm"
  service_account = "litellm"
  role_arn        = aws_iam_role.litellm_pod.arn
}
```

Deployment excerpt:

```yaml
spec:
  replicas: 2
  selector: { matchLabels: { app: litellm } }
  strategy:
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  template:
    metadata: { labels: { app: litellm } }
    spec:
      serviceAccountName: litellm
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 130 # stop_timeout (120 s) + preStop
      securityContext:
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: litellm
          image: ghcr.io/berriai/litellm:<tag>@sha256:<digest> # from terraform/app/container.tf
          args: ["--port", "4000", "--config", "/etc/litellm/config.yaml"]
          ports: [{ name: http, containerPort: 4000 }]
          env:
            - { name: DISABLE_SCHEMA_UPDATE, value: "true" }
            - { name: LITELLM_CONFIG_SHA, value: "<config sha256>" }
            - { name: REDIS_HOST, value: "<redis_endpoint>" }
            - { name: REDIS_PORT, value: "<redis_port>" }
            - { name: REDIS_SSL, value: "True" }
            - { name: AWS_REGION, value: "<region>" }
            # ... the other environment values of container.tf ...
            - name: DATABASE_URL
              valueFrom: { secretKeyRef: { name: litellm-secrets, key: DATABASE_URL } }
            # ... LITELLM_MASTER_KEY, LITELLM_SALT_KEY, REDIS_PASSWORD, UI_PASSWORD likewise ...
          startupProbe: # in place of the ECS start period (60 s)
            httpGet: { path: /health/liveliness, port: http }
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet: { path: /health/liveliness, port: http }
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 10
          readinessProbe:
            httpGet: { path: /health/liveliness, port: http }
            periodSeconds: 30
            timeoutSeconds: 10
            successThreshold: 2
            failureThreshold: 3
          lifecycle:
            preStop: { sleep: { seconds: 10 } } # Kubernetes 1.30 or later
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
          volumeMounts: [{ name: config, mountPath: /etc/litellm, readOnly: true }]
      volumes:
        - name: config
          configMap: { name: litellm-config-<sha16> }
```

Service excerpt (cluster-internal; put your ingress or load balancer in front of it):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: litellm
spec:
  selector: { app: litellm } # the Deployment's pod labels
  ports: [{ name: http, port: 4000, targetPort: http }]
```

Migration Job excerpt (same image, environment, secrets and config as the Deployment), named per image digest and
config hash:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: litellm-migrate-<digest12>-<sha12>
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1200
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: litellm
      automountServiceAccountToken: false
      securityContext:
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: migrate
          image: ghcr.io/berriai/litellm:<tag>@sha256:<digest>
          args: ["--port", "4000", "--config", "/etc/litellm/config.yaml", "--skip_server_startup"]
          env:
            - { name: DISABLE_SCHEMA_UPDATE, value: "false" }
            # ... otherwise the Deployment's environment and secrets ...
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
```

Apply the Deployment only after the Job completes (a failed Job ends this wait at the timeout):

```bash
kubectl -n litellm wait --for=condition=complete job/litellm-migrate-<digest12>-<sha12> --timeout=20m \
  && kubectl -n litellm apply -f deployment.yaml
```

Through `kubectl -n litellm port-forward service/litellm 4000:4000`, `deploy/smoke-test.sh` can check such a
gateway at `http://127.0.0.1:4000`.

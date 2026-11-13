# Moving from version 1 to version 2

Version 2 of this Guidance is a rewrite. It runs the stock LiteLLM proxy without the version 1 middleware, uses
different Terraform root modules and state, and creates its own database. There is no in-place upgrade: deploy
version 2 next to version 1, move your clients over, then destroy the version 1 deployment.

This page is guidance. Test the steps on a copy of your data, and keep version 1 running until version 2 works for
your clients.

## What changed

| Version 1 | Version 2 |
| --- | --- |
| Custom middleware in the request path | Removed. Clients call LiteLLM directly through its OpenAI-compatible API. |
| Server-side chat history (middleware) | Not available. Keep conversation history in your application. |
| Amazon Bedrock prompt ARNs as model IDs | Not available. Register models in LiteLLM (UI or API) and call them by name. |
| Amazon Bedrock-native interface (middleware) | Not available as such. LiteLLM's Amazon Bedrock pass-through routes may cover some clients; check yours. |
| Okta JWT authentication (middleware) | LiteLLM virtual keys, or LiteLLM JWT authentication with any OIDC identity provider (needs a LiteLLM Enterprise licence); see [JWT authentication for applications](deployment.md#jwt-authentication-for-applications). |
| Amazon CloudFront in front of the load balancer | Removed. Public mode uses an internet-facing load balancer with AWS WAF. |
| Amazon EKS deployment | Guidance only, not tested: [examples/eks](../examples/eks/README.md). |
| AWS Service Catalog AppRegistry application | Removed. |
| Per-Region configuration files and deployment scripts | One `deploy/terraform.tfvars` per deployment and `deploy/deploy.sh`; see [deployment.md](deployment.md). |
| LiteLLM 1.82 | LiteLLM 1.106 (pinned by digest in `terraform/app/container.tf`). |

Before you start, list what your version 1 deployment holds: the models and their provider credentials, the
teams, users, virtual keys and budgets, any custom LiteLLM configuration, your identity provider setup, and the
clients that call the gateway.

## Option A: start fresh

The simplest path. Nothing is carried over from version 1.

1. Deploy version 2 ([deployment.md](deployment.md)).
2. Recreate models, teams, users, budgets and virtual keys in the UI or through the LiteLLM API, and give the new
   keys to your clients.
3. Move the clients to the version 2 URL and check them.
4. Destroy the version 1 deployment. Spend history stays in version 1's database: export what you need first.

## Option B: keep the LiteLLM data

Carries version 1's LiteLLM database (models with their stored provider credentials, teams, users, virtual keys,
budgets and spend) into version 2. LiteLLM encrypts the stored provider credentials with its salt key, so version
2 must use version 1's salt key. Reusing the master key as well keeps existing administrative automation working.

What was tested: a local copy only, with LiteLLM 1.82.3 creating the data on PostgreSQL 17, then LiteLLM 1.106.6's
migration and server. The migration completed, and existing virtual keys, teams, users, models with stored
provider credentials, and spend kept working with version 1's salt key; with a different salt key, models with
stored credentials became unusable. It was not tested against a real version 1 deployment, so rehearse on a copy
of your data first.

1. **Copy the keys into two plain-string secrets.** Version 1 stores both keys in one JSON secret (name prefix
   `LiteLLMMasterSalt-`); version 2 expects one plain `sk-...` value per secret. The values go from one secret to
   the other without appearing on screen:

   ```bash
   V1_SECRET=<ARN of the version 1 LiteLLMMasterSalt- secret>
   for k in LITELLM_SALT_KEY LITELLM_MASTER_KEY; do
     aws secretsmanager get-secret-value --secret-id "$V1_SECRET" --query SecretString --output text |
       jq -j --arg k "$k" '.[$k]' |
       aws secretsmanager create-secret --name "llmgw-v1-$(echo "$k" | tr 'A-Z_' 'a-z-')" \
         --secret-string file:///dev/stdin --query ARN --output text
   done
   ```

   The secrets must be encrypted with the AWS managed key or with the deployment's `kms_key_arn`
   ([Customer managed KMS key](deployment.md#customer-managed-kms-key-optional)).
2. **Point version 2 at them** in `deploy/terraform.tfvars`:

   ```hcl
   existing_salt_key_secret_arn   = "<ARN printed for llmgw-v1-litellm-salt-key>"
   existing_master_key_secret_arn = "<ARN printed for llmgw-v1-litellm-master-key>"
   ```

3. **Create the version 2 database, but not the app yet.** Run `deploy/deploy.sh`, apply the foundation plan and
   answer anything but `yes` at the app plan. The database then exists and is empty.
4. **Copy the database.** Stop changes in version 1 (a maintenance window), then dump its LiteLLM database and
   restore it into version 2's, for example with `pg_dump --format=custom` and
   `pg_restore --no-owner --dbname=<version 2 database URL>`. Both use the database `litellm` and the user
   `llmproxy`. Version 2's connection URL is in the secret of the `database_url_secret_arn` foundation output.
   Both databases are in private subnets: run the commands from a machine or temporary task that can reach them,
   and copy the dump between the two networks if no single machine reaches both. Use a `pg_dump` at least as new
   as the version 1 database server.
5. **Deploy the app.** Run `deploy/deploy.sh` again and apply both plans. The migration task brings the restored
   schema forward before the service starts.
6. **Check it.** Run the [smoke test](deployment.md#smoke-test), call a model with an existing version 1 virtual
   key, and look at teams, keys and spend in the UI.
7. **Move the clients** to the version 2 URL. Changes made in version 1 after the dump are not carried over.
8. **Destroy the version 1 deployment** once version 2 serves your clients.

Server-side chat history from the version 1 middleware is not part of the LiteLLM database and is not carried
over.

#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { LitellmDatabaseCdkStack } from '../lib/litellm-database-cdk-stack';
import { DeploymentPlatform } from '../lib/litellm-database-cdk-stack';

const app = new cdk.App();
const vpcId = String(app.node.tryGetContext("vpcId"));
const deploymentPlatformString = String(app.node.tryGetContext("deploymentPlatform"));
const disableOutboundNetworkAccess = String(app.node.tryGetContext("disableOutboundNetworkAccess")).toLowerCase() === 'true';
const createVpcEndpointsInExistingVpc = String(app.node.tryGetContext("createVpcEndpointsInExistingVpc")).toLowerCase() === 'true';

// Validate and convert deployment platform string to enum
const deploymentPlatform = (() => {
  if (!deploymentPlatformString) {
    throw new Error('deploymentPlatform must be specified in context');
  }
  
  const platform = deploymentPlatformString.toUpperCase() as DeploymentPlatform;
  if (!Object.values(DeploymentPlatform).includes(platform)) {
    throw new Error(`Invalid deployment platform: ${deploymentPlatformString}. Must be one of: ${Object.values(DeploymentPlatform).join(', ')}`);
  }
  
  return platform;
})();

new LitellmDatabaseCdkStack(app, 'LitellmDatabaseCdkStack', {
  vpcId: vpcId,
  deploymentPlatform: deploymentPlatform,
  disableOutboundNetworkAccess: disableOutboundNetworkAccess,
  createVpcEndpointsInExistingVpc: createVpcEndpointsInExistingVpc,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION
  }
  /* If you don't specify 'env', this stack will be environment-agnostic.
   * Account/Region-dependent features and context lookups will not work,
   * but a single synthesized template can be deployed anywhere. */

  /* Uncomment the next line to specialize this stack for the AWS Account
   * and Region that are implied by the current CLI configuration. */
  // env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },

  /* Uncomment the next line if you know exactly what Account and Region you
   * want to deploy the stack to. */
  // env: { account: '123456789012', region: 'us-east-1' },

  /* For more information, see https://docs.aws.amazon.com/cdk/latest/guide/environments.html */
});
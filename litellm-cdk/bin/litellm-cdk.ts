#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { DeploymentPlatform, LitellmCdkStack } from '../lib/litellm-cdk-stack';


const app = new cdk.App();
const architecture = app.node.tryGetContext('architecture');
const liteLLMVersion = app.node.tryGetContext('liteLLMVersion');
const ecrLitellmRepository = String(app.node.tryGetContext("ecrLitellmRepository"));
const ecrMiddlewareRepository = String(app.node.tryGetContext("ecrMiddlewareRepository"));
const certificateArn = String(app.node.tryGetContext("certificateArn"));
const domainName = String(app.node.tryGetContext("domainName"));
const oktaIssuer = String(app.node.tryGetContext("oktaIssuer"));
const oktaAudience = String(app.node.tryGetContext("oktaAudience"));
const logBucketArn = String(app.node.tryGetContext("logBucketArn"));
const openaiApiKey = String(app.node.tryGetContext("openaiApiKey"));
const azureOpenAiApiKey = String(app.node.tryGetContext("azureOpenAiApiKey"));
const azureApiKey = String(app.node.tryGetContext("azureApiKey"));
const anthropicApiKey = String(app.node.tryGetContext("anthropicApiKey"));
const groqApiKey = String(app.node.tryGetContext("groqApiKey"));
const cohereApiKey = String(app.node.tryGetContext("cohereApiKey"));
const coApiKey = String(app.node.tryGetContext("coApiKey"));
const hfToken = String(app.node.tryGetContext("hfToken"));
const huggingfaceApiKey = String(app.node.tryGetContext("huggingfaceApiKey"));
const databricksApiKey = String(app.node.tryGetContext("databricksApiKey"));
const geminiApiKey = String(app.node.tryGetContext("geminiApiKey"));
const codestralApiKey = String(app.node.tryGetContext("codestralApiKey"));
const mistralApiKey = String(app.node.tryGetContext("mistralApiKey"));
const azureAiApiKey = String(app.node.tryGetContext("azureAiApiKey"));

const nvidiaNimApiKey = String(app.node.tryGetContext("nvidiaNimApiKey"));
const xaiApiKey = String(app.node.tryGetContext("xaiApiKey"));
const perplexityaiApiKey = String(app.node.tryGetContext("perplexityaiApiKey"));
const githubApiKey = String(app.node.tryGetContext("githubApiKey"));
const deepseekApiKey = String(app.node.tryGetContext("deepseekApiKey"));
const ai21ApiKey = String(app.node.tryGetContext("ai21ApiKey"));
const langsmithApiKey = String(app.node.tryGetContext("langsmithApiKey"));
const langsmithProject = String(app.node.tryGetContext("langsmithProject"));
const langsmithDefaultRunName = String(app.node.tryGetContext("langsmithDefaultRunName"));
const deploymentPlatformString = String(app.node.tryGetContext("deploymentPlatform"));
const vpcId = String(app.node.tryGetContext("vpcId"));
const eksClusterName = String(app.node.tryGetContext("eksClusterName"));

const rdsLitellmHostname = String(app.node.tryGetContext("rdsLitellmHostname"));
const rdsLitellmSecretArn = String(app.node.tryGetContext("rdsLitellmSecretArn"));
const rdsMiddlewareHostname = String(app.node.tryGetContext("rdsMiddlewareHostname"));
const rdsMiddlewareSecretArn = String(app.node.tryGetContext("rdsMiddlewareSecretArn"));
const redisHostName = String(app.node.tryGetContext("redisHostName"));
const redisPort = String(app.node.tryGetContext("redisPort"));
const rdsSecurityGroupId = String(app.node.tryGetContext("rdsSecurityGroupId"));
const redisSecurityGroupId = String(app.node.tryGetContext("redisSecurityGroupId"));
const eksNodeGroupRoleArn = String(app.node.tryGetContext("eksNodeGroupRoleArn"));
const eksOidcUrl = String(app.node.tryGetContext("eksOidcUrl"));

// Validate and convert deployment platform string to enum
const deploymentPlatform = (() => {
  if (!deploymentPlatformString) {
    throw new Error('deploymentPlatform must be specified in context');
  }
  
  const platform = deploymentPlatformString.toUpperCase() as DeploymentPlatform;
  if (!Object.values(DeploymentPlatform).includes(platform)) {
    throw new Error(`Invalid deployment platform: ${deploymentPlatformString}. Must be one of: ${Object.values(DeploymentPlatform).join(', ')}`);
  }

  // Validate VPC and EKS cluster requirements
  if (eksClusterName && (!vpcId || vpcId.trim() === '')) {
    throw new Error('When eksClusterName is provided, vpcId must also be specified');
  }
  
  return platform;
})();

new LitellmCdkStack(app, 'LitellmCdkStack', {
  domainName: domainName,
  certificateArn: certificateArn,
  oktaIssuer: oktaIssuer,
  oktaAudience: oktaAudience,
  liteLLMVersion: liteLLMVersion,
  architecture: architecture,
  ecrLitellmRepository: ecrLitellmRepository,
  ecrMiddlewareRepository: ecrMiddlewareRepository,
  logBucketArn: logBucketArn,
  openaiApiKey: openaiApiKey,
  azureOpenAiApiKey: azureOpenAiApiKey,
  azureApiKey: azureApiKey,
  anthropicApiKey: anthropicApiKey,
  groqApiKey: groqApiKey,
  cohereApiKey: cohereApiKey,
  coApiKey: coApiKey,
  hfToken: hfToken,
  huggingfaceApiKey: huggingfaceApiKey,
  databricksApiKey: databricksApiKey,
  geminiApiKey: geminiApiKey,
  codestralApiKey: codestralApiKey,
  mistralApiKey: mistralApiKey,
  azureAiApiKey: azureAiApiKey,
  nvidiaNimApiKey: nvidiaNimApiKey,
  xaiApiKey: xaiApiKey,
  perplexityaiApiKey: perplexityaiApiKey,
  githubApiKey: githubApiKey,
  deepseekApiKey: deepseekApiKey,
  ai21ApiKey: ai21ApiKey,
  langsmithApiKey: langsmithApiKey,
  langsmithProject: langsmithProject,
  langsmithDefaultRunName: langsmithDefaultRunName,
  deploymentPlatform: deploymentPlatform,
  vpcId: vpcId,
  eksClusterName: eksClusterName,
  oidcUrl: eksOidcUrl,
  rdsLitellmHostname: rdsLitellmHostname,
  rdsLitellmSecretArn: rdsLitellmSecretArn,
  rdsMiddlewareHostname: rdsMiddlewareHostname,
  rdsMiddlewareSecretArn: rdsMiddlewareSecretArn,
  redisHostName: redisHostName,
  redisPort: redisPort,
  rdsSecurityGroupId: rdsSecurityGroupId,
  redisSecurityGroupId: redisSecurityGroupId,
  eksNodeGroupRoleArn: eksNodeGroupRoleArn,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION
  }
});

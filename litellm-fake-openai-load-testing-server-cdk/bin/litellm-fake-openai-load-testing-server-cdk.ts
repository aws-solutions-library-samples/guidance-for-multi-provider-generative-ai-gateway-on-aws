#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { LitellmFakeOpenaiLoadTestingServerCdkStack } from '../lib/litellm-fake-openai-load-testing-server-cdk-stack';

const app = new cdk.App();
const vpcId = String(app.node.tryGetContext("vpcId"));
const certificateArn = String(app.node.tryGetContext("certificateArn"));
const hostedZoneName = String(app.node.tryGetContext("hostedZoneName"));
const domainName = String(app.node.tryGetContext("domainName"));
const ecrFakeServerRepository = String(app.node.tryGetContext("ecrFakeServerRepository"));
const architecture = String(app.node.tryGetContext("architecture"));

new LitellmFakeOpenaiLoadTestingServerCdkStack(app, 'LitellmFakeOpenaiLoadTestingServerCdkStack', {
  vpcId: vpcId,
  certificateArn: certificateArn,
  hostedZoneName: hostedZoneName,
  domainName: domainName,
  ecrFakeServerRepository: ecrFakeServerRepository,
  architecture: architecture,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION
  }
});
#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { LitellmEksClusterNodeGroupCdkStack } from '../lib/litellm-eks-cluster-node-group-cdk-stack';

const app = new cdk.App();
const architecture = app.node.tryGetContext('architecture');
const vpcId = String(app.node.tryGetContext("vpcId"));
const eksClusterName = String(app.node.tryGetContext("eksClusterName"));
const eksOidcUrl = String(app.node.tryGetContext("eksOidcUrl"));

new LitellmEksClusterNodeGroupCdkStack(app, 'LitellmEksClusterNodeGroupCdkStack', {
  vpcId: vpcId,
  eksClusterName: eksClusterName,
  oidcUrl: eksOidcUrl,
  architecture: architecture,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION
  }
});
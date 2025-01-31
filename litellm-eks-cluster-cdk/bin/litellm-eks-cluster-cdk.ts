#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { LitellmEksClusterCdkStack } from '../lib/litellm-eks-cluster-cdk-stack';

const app = new cdk.App();
const architecture = app.node.tryGetContext('architecture');

new LitellmEksClusterCdkStack(app, 'LitellmEksClusterCdkStack', {
  architecture: architecture
});
#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { LitellmPrivateLoadBalancerEc2Stack } from '../lib/litellm-private-load-balancer-ec2-stack';

const app = new cdk.App();
const vpcId = String(app.node.tryGetContext("vpcId"));
const keyPairName = String(app.node.tryGetContext("keyPairName"));

new LitellmPrivateLoadBalancerEc2Stack(app, 'LitellmPrivateLoadBalancerEc2Stack', {  
  vpcId: vpcId,
  keyPairName: keyPairName,

  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION
  }
});
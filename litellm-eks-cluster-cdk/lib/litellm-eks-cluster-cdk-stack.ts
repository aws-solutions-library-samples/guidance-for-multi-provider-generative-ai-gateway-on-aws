import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { KubectlV26Layer } from '@aws-cdk/lambda-layer-kubectl-v26';
import * as iam from 'aws-cdk-lib/aws-iam';
import { execSync } from 'child_process';

// import * as sqs from 'aws-cdk-lib/aws-sqs';

interface LiteLLMStackProps extends cdk.StackProps {
  architecture: string;
}

export class LitellmEksClusterCdkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: LiteLLMStackProps) {
    super(scope, id, props);

    const vpc = new ec2.Vpc(this, 'LiteLLMVpc', {
      maxAzs: 2,
      natGateways: 1,
    });

    const eksCluster = new eks.Cluster(this, 'HelloEKS', {
      version: eks.KubernetesVersion.V1_31,
      vpc,
      defaultCapacity: 0,
      kubectlLayer: new KubectlV26Layer(this, 'KubectlLayer'),
    });

    let rawArn: string;
    let accountId: string;
    try {
      const rawJson = execSync('aws sts get-caller-identity --output json', { encoding: 'utf-8' });
      const identity = JSON.parse(rawJson);
      rawArn = identity.Arn;       // e.g. arn:aws:sts::123456789012:assumed-role/Admin/SessionName
      accountId = identity.Account; // e.g. 123456789012
    } catch (error) {
      throw new Error(`Failed to run "aws sts get-caller-identity". Make sure AWS CLI is installed and configured.\n${error}`);
    }

    // 2) Parse out the base IAM role from the assumed-role ARN
    //    e.g. "arn:aws:sts::123456789012:assumed-role/Admin/SessionName"
    //         => "arn:aws:iam::123456789012:role/Admin"
    const arnParts = rawArn.split(':'); // [ 'arn','aws','sts','','123456789012','assumed-role/Admin/SessionName' ]
    if (arnParts[2] !== 'sts') {
      // It might be a user ARN: e.g. arn:aws:iam::123456789012:user/MyUser
      // or something else
      // We'll handle that differently below.
    }
    let baseRoleArn: string | undefined;
    const lastPart = arnParts[5]; // e.g. 'assumed-role/Admin/SessionName'
    if (lastPart.startsWith('assumed-role/')) {
      // "assumed-role/Admin/SessionName"
      const subParts = lastPart.split('/');
      // subParts = [ 'assumed-role','Admin','SessionName' ]
      const roleName = subParts[1]; // "Admin"
      baseRoleArn = `arn:aws:iam::${accountId}:role/${roleName}`;
    } else {
      // e.g. user ARN or root
      // fallback to the entire rawArn if you want
      // but that won't help if you're ephemeral.
      baseRoleArn = rawArn.replace(':sts:', ':iam:').replace('assumed-role', 'role');
      // This naive approach might break if it's not actually an assumed role.
      // Or just skip if we don't know how to parse it.
    }

    if (!baseRoleArn) {
      throw new Error(`Could not parse a base role from: ${rawArn}`);
    }

    // 4) Import the stable base role, then map it to system:masters
    const deployerRole = iam.Role.fromRoleArn(this, 'CdkDeployerRole', baseRoleArn, {
      mutable: false,
    });

    eksCluster.awsAuth.addMastersRole(deployerRole);
    // Add this right after:
    // Also map the assumed-role pattern for the same role
    const assumedRoleArn = baseRoleArn.replace(
      'arn:aws:iam::',
      'arn:aws:sts::'
    ).replace(
      'role/',
      'assumed-role/'
    );

    // Add both patterns to aws-auth
    eksCluster.awsAuth.addRoleMapping(
      iam.Role.fromRoleArn(this, 'AssumedDeployerRole', assumedRoleArn, {
        mutable: false,
      }),
      {
        username: assumedRoleArn,
        groups: ['system:masters']
      }
    );
    new cdk.CfnOutput(this, 'VpcId', {
      value: vpc.vpcId,
      description: 'The ID of the VPC',
      exportName: 'VpcId',
    });
    
    new cdk.CfnOutput(this, 'EksClusterName', {
      value: eksCluster.clusterName,
      description: 'The name of the EKS cluster',
      exportName: 'EksClusterName',
    });

    new cdk.CfnOutput(this, 'EksClusterKubectlRoleArn', {
      // .kubectlRole is the role the CDK uses to interact with the cluster at deploy time
      value: eksCluster.kubectlRole?.roleArn || 'undefined',
      exportName: 'EksClusterKubectlRoleArn',
    });

    new cdk.CfnOutput(this, 'EksClusterKubectlLambdaRoleArn', {
      // .kubectlRole is the role the CDK uses to interact with the cluster at deploy time
      value: eksCluster.kubectlLambdaRole?.roleArn || 'undefined',
      exportName: 'EksClusterKubectlLambdaRoleArn',
    });
    
  }
}

import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';

interface LiteLLMStackProps extends cdk.StackProps {
  vpcId: string;
  eksClusterName: string;
  oidcUrl: string;
  architecture: string;
}

export class LitellmEksClusterNodeGroupCdkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: LiteLLMStackProps) {
    super(scope, id, props);

    const vpc = ec2.Vpc.fromLookup(this, 'ImportedVpc', { vpcId: props.vpcId })

    const eksCluster = eks.Cluster.fromClusterAttributes(this, 'ImportedCluster', {
      clusterName: props.eksClusterName,
      vpc: vpc,
      // If your chart or service account relies on IRSA, you must provide the OIDC provider:
      openIdConnectProvider: iam.OpenIdConnectProvider.fromOpenIdConnectProviderArn(
        this,
        'OIDCProvider',
        `arn:aws:iam::${this.account}:oidc-provider/${props.oidcUrl}`
      ),
      kubectlRoleArn: "arn:aws:iam::235614385815:role/LitellmEksClusterCdkStack-HelloEKSCreationRole089CC-i3gKQrICW6XJ",
      kubectlLambdaRole: iam.Role.fromRoleArn(this, 'ImportedRole', 'arn:aws:iam::235614385815:role/LitellmEksClusterCdkStack-HelloEKSKubectlHandlerRol-mNZVEzk7piwk')
    });

    const nodegroup = new eks.Nodegroup(this, 'additional-nodegroup', {
        cluster: eksCluster,
        instanceTypes: [ec2.InstanceType.of(
          props.architecture === "x86" ? ec2.InstanceClass.T3 : ec2.InstanceClass.T4G,
          ec2.InstanceSize.MEDIUM
        )],      
        minSize: 1,
        maxSize: 3,
        desiredSize: 1,
        amiType: props.architecture === "x86" 
          ? eks.NodegroupAmiType.AL2_X86_64 
          : eks.NodegroupAmiType.AL2_ARM_64,
      });

      new cdk.CfnOutput(this, 'EksNodeGroupRoleArn', {
        value: nodegroup.role.roleArn,
        description: 'The name of the EKS node group role arn',
        exportName: 'EksNodeGroupRoleArn',
      });
  }
}

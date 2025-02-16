import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
// import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as ecrAssets from 'aws-cdk-lib/aws-ecr-assets';
import * as path from 'path';
import * as certificatemanager from 'aws-cdk-lib/aws-certificatemanager';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as ecs_patterns from 'aws-cdk-lib/aws-ecs-patterns';
import * as elasticloadbalancingv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as ecr from "aws-cdk-lib/aws-ecr";

interface LiteLLMStackProps extends cdk.StackProps {
  vpcId: string;
  certificateArn: string;
  hostedZoneName: string;
  domainName: string;
  ecrFakeServerRepository: string;
  architecture: string;
}

export class LitellmFakeOpenaiLoadTestingServerCdkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: LiteLLMStackProps) {
    super(scope, id, props);

    const vpc = ec2.Vpc.fromLookup(this, 'VPC', {
      vpcId: props.vpcId
    });

    const cluster = new ecs.Cluster(this, 'FakeOpenAICluster', {
      vpc,
    });

    const certificate = certificatemanager.Certificate.fromCertificateArn(
      this,
      'MyCert',
      props.certificateArn
    );

    const hostedZone = route53.HostedZone.fromLookup(this, 'HostedZone', {
      domainName: props.hostedZoneName
    });

    const ecrFakeServerRepository = ecr.Repository.fromRepositoryName(
      this,
      props.ecrFakeServerRepository!,
      props.ecrFakeServerRepository!
    );

    // Create Task Definition
    const taskDefinition = new ecs.FargateTaskDefinition(this, 'LiteLLMTaskDef', {
      memoryLimitMiB: 1024,
      cpu: 512,
      runtimePlatform: {
        cpuArchitecture: props.architecture == "x86" ? ecs.CpuArchitecture.X86_64 : ecs.CpuArchitecture.ARM64,
        operatingSystemFamily: ecs.OperatingSystemFamily.LINUX
      },
    });

    // Add container to task definition
    const container = taskDefinition.addContainer('LiteLLMContainer', {
      image: ecs.ContainerImage.fromEcrRepository(ecrFakeServerRepository, "latest"),
      logging: ecs.LogDrivers.awsLogs({ streamPrefix: 'FakeServer' }),
    });

    const fargateService = new ecs_patterns.ApplicationMultipleTargetGroupsFargateService(this, 'LiteLLMService', {
      cluster,
      taskDefinition,
      serviceName: "FakeServer",
      loadBalancers: [
        {
          name: 'ALB',
          publicLoadBalancer: true,
          domainName: props.domainName,
          domainZone: hostedZone,
          listeners: [
            {
              name: 'Listener',
              protocol: elasticloadbalancingv2.ApplicationProtocol.HTTPS,
              certificate: certificate,
              sslPolicy: elasticloadbalancingv2.SslPolicy.RECOMMENDED_TLS,
            },
          ],
        },
      ],
      targetGroups: [
        {
          containerPort: 8080,
          listener: 'Listener',
        }
      ],
      desiredCount: 1,
      healthCheckGracePeriod: cdk.Duration.seconds(300),
    });

    //fargateService.service.connections.allowFromAnyIpv4(ec2.Port.tcp(443), 'Allow inbound HTTPS');

    new cdk.CfnOutput(this, 'LitellmEcsCluster', {
      value: cluster.clusterName,
      description: 'Name of the ECS Cluster'
    });

    new cdk.CfnOutput(this, 'LitellmEcsTask', {
      value: fargateService.service.serviceName,
      description: 'Name of the task service'
    });

    new cdk.CfnOutput(this, 'ServiceURL', {
      value: `https://${props.domainName}`,
    });
  }
}

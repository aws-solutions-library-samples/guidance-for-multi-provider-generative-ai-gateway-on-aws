import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as ecs_patterns from 'aws-cdk-lib/aws-ecs-patterns';
import * as rds from 'aws-cdk-lib/aws-rds';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';
import * as elasticloadbalancingv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as certificatemanager from 'aws-cdk-lib/aws-certificatemanager';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ecr from "aws-cdk-lib/aws-ecr";
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as path from 'path';
import * as cr from 'aws-cdk-lib/custom-resources';
import * as elasticache from 'aws-cdk-lib/aws-elasticache';
import { Tag, Aspects } from 'aws-cdk-lib';
import * as wafv2 from 'aws-cdk-lib/aws-wafv2';

interface LiteLLMStackProps extends cdk.StackProps {
  domainName: string;
  certificateArn: string;
  oktaIssuer: string;
  oktaAudience: string;
  liteLLMVersion: string;
  architecture: string;
  ecrLitellmRepository: string;
  ecrMiddlewareRepository: string;
  logBucketArn: string;
  openaiApiKey: string;
  azureOpenAiApiKey: string;
  azureApiKey: string;
  anthropicApiKey: string;
  groqApiKey: string;
  cohereApiKey: string;
  coApiKey: string;
  hfToken: string;
  huggingfaceApiKey: string;
  databricksApiKey: string;
  geminiApiKey: string;
  codestralApiKey: string;
  mistralApiKey: string;
  azureAiApiKey: string;
  nvidiaNimApiKey: string;
  xaiApiKey: string;
  perplexityaiApiKey: string;
  githubApiKey: string;
  deepseekApiKey: string;
}

export class LitellmCdkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: LiteLLMStackProps) {
    super(scope, id, props);

    Aspects.of(this).add(new Tag('stack-id', this.stackName));

    const configBucket = new s3.Bucket(this, 'LiteLLMConfigBucket', {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
    });

    new s3deploy.BucketDeployment(this, 'DeployConfig', {
      sources: [s3deploy.Source.asset(path.join(__dirname, '../', "../", "config"))],
      destinationBucket: configBucket,
      include: ['config.yaml'], // Only include config.yaml
      exclude: ['*'],
    });

    // Create VPC
    const vpc = new ec2.Vpc(this, 'LiteLLMVpc', {
      maxAzs: 2,
      natGateways: 1,
    });

    // Create ECS Cluster
    const cluster = new ecs.Cluster(this, 'LiteLLMCluster', {
      vpc,
      containerInsights: true,
    });

    // Create RDS Instance
    const databaseSecret = new secretsmanager.Secret(this, 'DBSecret', {
      generateSecretString: {
        secretStringTemplate: JSON.stringify({
          username: 'llmproxy',
        }),
        generateStringKey: 'password',
        excludePunctuation: true,
      },
    });

    const databaseMiddlewareSecret = new secretsmanager.Secret(this, 'DBMiddlewareSecret', {
      generateSecretString: {
        secretStringTemplate: JSON.stringify({
          username: 'middleware',
        }),
        generateStringKey: 'password',
        excludePunctuation: true,
      },
    });

    const dbSecurityGroup = new ec2.SecurityGroup(this, 'DBSecurityGroup', {
      vpc,
      description: 'Security group for RDS instance',
      allowAllOutbound: true,
    });

    const database = new rds.DatabaseInstance(this, 'Database', {
      engine: rds.DatabaseInstanceEngine.postgres({
        version: rds.PostgresEngineVersion.VER_15,
      }),
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MICRO),
      vpc,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
      },
      securityGroups: [dbSecurityGroup],
      credentials: rds.Credentials.fromSecret(databaseSecret),
      databaseName: 'litellm',
    });

    const databaseMiddleware = new rds.DatabaseInstance(this, 'DatabaseMiddleware', {
      engine: rds.DatabaseInstanceEngine.postgres({
        version: rds.PostgresEngineVersion.VER_15,
      }),
      instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MICRO),
      vpc,
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
      },
      securityGroups: [dbSecurityGroup],
      credentials: rds.Credentials.fromSecret(databaseMiddlewareSecret),
      databaseName: 'middleware',
    });

    const redisSecurityGroup = new ec2.SecurityGroup(this, 'RedisSecurityGroup', {
      vpc,
      description: 'Security group for Redis cluster',
      allowAllOutbound: true,
    });

    // Create Redis Subnet Group
    const redisSubnetGroup = new elasticache.CfnSubnetGroup(this, 'RedisSubnetGroup', {
      description: 'Subnet group for Redis cluster',
      subnetIds: vpc.privateSubnets.map(subnet => subnet.subnetId),
      cacheSubnetGroupName: 'litellm-redis-subnet-group',
    });

    const redisParameterGroup = new elasticache.CfnParameterGroup(this, 'RedisParameterGroup', {
      cacheParameterGroupFamily: 'redis7',
      description: 'Redis parameter group',
    });

    // Create Redis Cluster
    const redis = new elasticache.CfnReplicationGroup(this, 'RedisCluster', {
      replicationGroupDescription: 'Redis cluster',
      engine: 'redis',
      cacheNodeType: 'cache.t3.micro',
      numCacheClusters: 2,
      automaticFailoverEnabled: true,
      cacheParameterGroupName: redisParameterGroup.ref,
      cacheSubnetGroupName: redisSubnetGroup.ref,
      securityGroupIds: [redisSecurityGroup.securityGroupId],
      engineVersion: '7.0',
      port: 6379,
    });

    // Make sure the subnet group is created before the cluster
    redis.addDependency(redisSubnetGroup);
    redis.addDependency(redisParameterGroup);

    // Create LiteLLM Secret
    const litellmMasterAndSaltKeySecret = new secretsmanager.Secret(this, 'LiteLLMSecret', {
      generateSecretString: {
        secretStringTemplate: JSON.stringify({
          LITELLM_MASTER_KEY: 'placeholder',
          LITELLM_SALT_KEY: 'placeholder',
        }),
        generateStringKey: 'dummy',
      },
    });

    const litellmOtherSecrets = new secretsmanager.Secret(this, 'LiteLLMApiKeySecret', {
      generateSecretString: {
        secretStringTemplate: JSON.stringify({
          OPENAI_API_KEY: props.openaiApiKey,
          AZURE_OPENAI_API_KEY: props.azureOpenAiApiKey,
          AZURE_API_KEY: props.azureApiKey,
          ANTHROPIC_API_KEY: props.anthropicApiKey,
          GROQ_API_KEY: props.groqApiKey,
          COHERE_API_KEY: props.cohereApiKey,
          CO_API_KEY: props.coApiKey,
          HF_TOKEN: props.hfToken,
          HUGGINGFACE_API_KEY: props.huggingfaceApiKey,
          DATABRICKS_API_KEY: props.databricksApiKey,
          GEMINI_API_KEY: props.geminiApiKey,
          CODESTRAL_API_KEY: props.codestralApiKey,
          MISTRAL_API_KEY: props.mistralApiKey,
          AZURE_AI_API_KEY: props.azureAiApiKey,
          NVIDIA_NIM_API_KEY: props.nvidiaNimApiKey,
          XAI_API_KEY: props.xaiApiKey,
          PERPLEXITYAI_API_KEY: props.perplexityaiApiKey,
          GITHUB_API_KEY: props.githubApiKey,
          DEEPSEEK_API_KEY: props.deepseekApiKey,
        }),
        generateStringKey: 'dummy',
      },
    });

    const generateSecretKeys = new cr.AwsCustomResource(this, 'GenerateSecretKeys', {
      onCreate: {
        service: 'SecretsManager',
        action: 'putSecretValue',
        parameters: {
          SecretId: litellmMasterAndSaltKeySecret.secretArn,
          SecretString: JSON.stringify({
            LITELLM_MASTER_KEY: 'sk-' + Math.random().toString(36).substring(2),
            LITELLM_SALT_KEY: 'sk-' + Math.random().toString(36).substring(2),
          }),
        },
        physicalResourceId: cr.PhysicalResourceId.of('SecretInitializer'),
      },
      policy: cr.AwsCustomResourcePolicy.fromSdkCalls({
        resources: [litellmMasterAndSaltKeySecret.secretArn],
      }),
    });
    litellmMasterAndSaltKeySecret.grantWrite(generateSecretKeys);
    
    // Create Task Definition
    const taskDefinition = new ecs.FargateTaskDefinition(this, 'LiteLLMTaskDef', {
      memoryLimitMiB: 1024,
      cpu: 512,
      runtimePlatform: {
        cpuArchitecture: props.architecture == "x86" ? ecs.CpuArchitecture.X86_64 : ecs.CpuArchitecture.ARM64,
        operatingSystemFamily: ecs.OperatingSystemFamily.LINUX
      },
    });

    taskDefinition.addToTaskRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['s3:GetObject', 's3:ListBucket'],
      resources: [configBucket.bucketArn, `${configBucket.bucketArn}/*`],
    }));

    taskDefinition.addToTaskRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        's3:*',
      ],
      resources: [props.logBucketArn, `${props.logBucketArn}/*`],
    }));
    
    taskDefinition.taskRole.addToPrincipalPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'bedrock:*', // Full access to Bedrock
      ],
      resources: ['*']
    }));

    taskDefinition.taskRole.addToPrincipalPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'sagemaker:InvokeEndpoint',
      ],
      resources: ['*']
    }));    

    // Create a custom secret for the database URL
    const dbUrlSecret = new secretsmanager.Secret(this, 'DBUrlSecret', {
      secretStringValue: cdk.SecretValue.unsafePlainText(
        `postgresql://llmproxy:${databaseSecret.secretValueFromJson('password').unsafeUnwrap()}@${database.instanceEndpoint.hostname}:5432/litellm`
      ),
    });

    const dbMiddlewareUrlSecret = new secretsmanager.Secret(this, 'DBMiddlewareUrlSecret', {
      secretStringValue: cdk.SecretValue.unsafePlainText(
        `postgresql://middleware:${databaseMiddlewareSecret.secretValueFromJson('password').unsafeUnwrap()}@${databaseMiddleware.instanceEndpoint.hostname}:5432/middleware`
      ),
    });

    const ecrLitellmRepository = ecr.Repository.fromRepositoryName(
      this,
      props.ecrLitellmRepository!,
      props.ecrLitellmRepository!
    );

    // Add container to task definition
    const container = taskDefinition.addContainer('LiteLLMContainer', {
      image: ecs.ContainerImage.fromEcrRepository(ecrLitellmRepository, props.liteLLMVersion),
      logging: ecs.LogDrivers.awsLogs({ streamPrefix: 'LiteLLM' }),
      secrets: {
        DATABASE_URL: ecs.Secret.fromSecretsManager(dbUrlSecret),
        LITELLM_MASTER_KEY: ecs.Secret.fromSecretsManager(litellmMasterAndSaltKeySecret, 'LITELLM_MASTER_KEY'),
        UI_PASSWORD: ecs.Secret.fromSecretsManager(litellmMasterAndSaltKeySecret, 'LITELLM_MASTER_KEY'),
        LITELLM_SALT_KEY: ecs.Secret.fromSecretsManager(litellmMasterAndSaltKeySecret, 'LITELLM_SALT_KEY'),
        OPENAI_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'OPENAI_API_KEY'),
        AZURE_OPENAI_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'AZURE_OPENAI_API_KEY'),
        AZURE_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'AZURE_API_KEY'),
        ANTHROPIC_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'ANTHROPIC_API_KEY'),
        GROQ_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'GROQ_API_KEY'),
        COHERE_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'COHERE_API_KEY'),
        CO_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'CO_API_KEY'),
        HF_TOKEN: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'HF_TOKEN'),
        HUGGINGFACE_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'HUGGINGFACE_API_KEY'),
        DATABRICKS_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'DATABRICKS_API_KEY'),
        GEMINI_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'GEMINI_API_KEY'),
        CODESTRAL_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'CODESTRAL_API_KEY'),
        MISTRAL_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'MISTRAL_API_KEY'),
        AZURE_AI_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'AZURE_AI_API_KEY'),
        NVIDIA_NIM_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'NVIDIA_NIM_API_KEY'),
        XAI_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'XAI_API_KEY'),
        PERPLEXITYAI_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'PERPLEXITYAI_API_KEY'),
        GITHUB_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'GITHUB_API_KEY'),
        DEEPSEEK_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'DEEPSEEK_API_KEY'),
      },
      environment: {
        LITELLM_CONFIG_BUCKET_NAME: configBucket.bucketName,
        LITELLM_CONFIG_BUCKET_OBJECT_KEY: 'config.yaml',
        UI_USERNAME: "admin",
        REDIS_URL: `redis://${redis.attrPrimaryEndPointAddress}:${redis.attrPrimaryEndPointPort}`
      }
    });

    const ecrMiddlewareRepository = ecr.Repository.fromRepositoryName(
      this,
      props.ecrMiddlewareRepository!,
      props.ecrMiddlewareRepository!
    );

    const middlewareContainer = taskDefinition.addContainer('MiddlewareContainer', {
      image: ecs.ContainerImage.fromEcrRepository(ecrMiddlewareRepository, "latest"),
      logging: ecs.LogDrivers.awsLogs({ streamPrefix: 'Middleware' }),
      secrets: {
        DATABASE_MIDDLEWARE_URL: ecs.Secret.fromSecretsManager(dbMiddlewareUrlSecret),
        MASTER_KEY: ecs.Secret.fromSecretsManager(litellmMasterAndSaltKeySecret, 'LITELLM_MASTER_KEY'),
      },
      environment: {
        OKTA_ISSUER: props.oktaIssuer,
        OKTA_AUDIENCE: props.oktaAudience,
      }
    });  

    const domainParts = props.domainName.split(".");
    const domainName = domainParts.slice(1).join(".");
    const hostName = domainParts[0];

    // Retrieve the existing Route 53 hosted zone
    const hostedZone = route53.HostedZone.fromLookup(this, 'Zone', {
      domainName: `${domainName}.`
    });

    const certificate = certificatemanager.Certificate.fromCertificateArn(this, 'Certificate', 
      props.certificateArn
    );

    const fargateService = new ecs_patterns.ApplicationMultipleTargetGroupsFargateService(this, 'LiteLLMService', {
      cluster,
      taskDefinition,
      serviceName: "LiteLLMService",
      loadBalancers: [
        {
          name: 'ALB',
          publicLoadBalancer: true,
          domainName: `${domainName}.`,
          domainZone: hostedZone,
          listeners: [
            {
              name: 'Listener',
              protocol: elasticloadbalancingv2.ApplicationProtocol.HTTPS,
              certificate: certificate,
              sslPolicy: elasticloadbalancingv2.SslPolicy.RECOMMENDED,
            },
          ],
        },
      ],
      targetGroups: [
        {
          containerPort: 4000,
          listener: 'Listener',
        },
        {
          containerPort: 3000,
          listener: 'Listener',
          priority: 5,
          pathPattern: '/bedrock/model/*',
        }
      ],
      desiredCount: 1,
      healthCheckGracePeriod: cdk.Duration.seconds(300),
    });

    const listener = fargateService.listeners[0]; // The previously created listener
    const targetGroup = fargateService.targetGroups[1]; // The main target group created

    // Add additional rules with multiple conditions, all pointing to the same targetGroup
    listener.addAction('OpenAIPaths', {
      priority: 6,
      conditions: [
        elasticloadbalancingv2.ListenerCondition.pathPatterns(['/v1/chat/completions', '/chat/completions', '/chat-history', '/bedrock/chat-history', '/bedrock/health/liveliness']),
      ],
      action: elasticloadbalancingv2.ListenerAction.forward([targetGroup]),
    });

    listener.addAction('MorePaths', {
      priority: 7,
      conditions: [
        elasticloadbalancingv2.ListenerCondition.pathPatterns(['/session-ids', '/key/generate', '/user/new']),
      ],
      action: elasticloadbalancingv2.ListenerAction.forward([targetGroup]),
    });


    redisSecurityGroup.addIngressRule(
      fargateService.service.connections.securityGroups[0],
      ec2.Port.tcp(6379),
      'Allow ECS tasks to connect to Redis'
    );

    const targetGroupLlmGateway = fargateService.targetGroups[0];
    targetGroupLlmGateway.configureHealthCheck({
      path: '/health/liveliness',
      port: '4000',
      protocol: elasticloadbalancingv2.Protocol.HTTP,
      healthyThresholdCount: 2,
      unhealthyThresholdCount: 3,
      timeout: cdk.Duration.seconds(10),
      interval: cdk.Duration.seconds(30),
    });

    const targetGroupMiddleware = fargateService.targetGroups[1];
    targetGroupMiddleware.configureHealthCheck({
      path: '/bedrock/health/liveliness',
      port: '3000',
      protocol: elasticloadbalancingv2.Protocol.HTTP,
      healthyThresholdCount: 2,
      unhealthyThresholdCount: 3,
      timeout: cdk.Duration.seconds(10),
      interval: cdk.Duration.seconds(30),
    });

    new route53.ARecord(this, 'DNSRecord', {
      zone: hostedZone,
      target: route53.RecordTarget.fromAlias(
        new targets.LoadBalancerTarget(fargateService.loadBalancers[0])
      ),
      recordName: props.domainName,  // This will be the full domain name
    });

    // Create a WAF Web ACL
    const webAcl = new wafv2.CfnWebACL(this, 'LiteLLMWAF', {
      defaultAction: { allow: {} },
      scope: 'REGIONAL', // Must be REGIONAL for ALB
      visibilityConfig: {
        cloudWatchMetricsEnabled: true,
        metricName: 'LiteLLMWebAcl',
        sampledRequestsEnabled: true,
      },
      rules: [
        {
          name: 'AWS-AWSManagedRulesCommonRuleSet',
          priority: 1,
          overrideAction: { none: {} },
          statement: {
            managedRuleGroupStatement: {
              name: 'AWSManagedRulesCommonRuleSet',
              vendorName: 'AWS',
            },
          },
          visibilityConfig: {
            cloudWatchMetricsEnabled: true,
            metricName: 'LiteLLMCommonRuleSet',
            sampledRequestsEnabled: true,
          },
        },
        // You can add more rules or managed rule groups here
      ],
    });

    // Associate the WAF Web ACL with your existing ALB
    new wafv2.CfnWebACLAssociation(this, 'LiteLLMWAFALBAssociation', {
      resourceArn: fargateService.loadBalancers[0].loadBalancerArn,
      webAclArn: webAcl.attrArn,
    });

    dbSecurityGroup.addIngressRule(
      fargateService.service.connections.securityGroups[0],
      ec2.Port.tcp(5432),
      'Allow ECS tasks to connect to RDS'
    );

    const scaling = fargateService.service.autoScaleTaskCount({
      maxCapacity: 4,
      minCapacity: 1,
    });

    scaling.scaleOnCpuUtilization('CpuScaling', {
      targetUtilizationPercent: 70,
    });

    new cdk.CfnOutput(this, 'ServiceURL', {
      value: `https://${props.domainName}`,
    });

    new cdk.CfnOutput(this, 'LitellmEcsCluster', {
      value: cluster.clusterName,
      description: 'Name of the ECS Cluster'
    });

    new cdk.CfnOutput(this, 'LitellmEcsTask', {
      value: fargateService.service.serviceName,
      description: 'Name of the task service'
    });

  }
}

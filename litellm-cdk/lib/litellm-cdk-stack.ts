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
import * as eks from 'aws-cdk-lib/aws-eks';
import { KubectlV26Layer } from '@aws-cdk/lambda-layer-kubectl-v26';
import { Fn } from 'aws-cdk-lib';
import { execSync } from 'child_process';
import * as route53targets from 'aws-cdk-lib/aws-route53-targets';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as lambda from 'aws-cdk-lib/aws-lambda';

export enum DeploymentPlatform {
  ECS = 'ECS',
  EKS = 'EKS'
}

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
  ai21ApiKey: string;
  langsmithApiKey: string;
  langsmithProject: string;
  langsmithDefaultRunName: string;
  deploymentPlatform: DeploymentPlatform;
  vpcId: string;
}

class IngressAlias implements route53.IAliasRecordTarget {
  constructor(
    private readonly dnsName: string,
    private readonly hostedZoneId: string
  ) {}

  bind(_record: route53.IRecordSet, _zone?: route53.IHostedZone): route53.AliasRecordTargetConfig {
    return {
      dnsName: this.dnsName,
      hostedZoneId: this.hostedZoneId
    };
  }
}


export class LitellmCdkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: LiteLLMStackProps) {
    super(scope, id, props);

    Aspects.of(this).add(new Tag('stack-id', this.stackName));

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

    // Create VPC or import one if provided
    const vpc = props.vpcId ? ec2.Vpc.fromLookup(this, 'ImportedVpc', { vpcId: props.vpcId }) : new ec2.Vpc(this, 'LiteLLMVpc', { maxAzs: 2, natGateways: 1 });

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
      storageType: rds.StorageType.GP3,
      storageEncrypted: true,
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
      storageType: rds.StorageType.GP3,
      storageEncrypted: true,
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
          AI21_API_KEY: props.ai21ApiKey,
          LANGSMITH_API_KEY: props.langsmithApiKey
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

    const ecrMiddlewareRepository = ecr.Repository.fromRepositoryName(
      this,
      props.ecrMiddlewareRepository!,
      props.ecrMiddlewareRepository!
    );

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
              excludedRules: [
                {
                  name: 'NoUserAgent_HEADER'
                },
                {
                  name: 'SizeRestrictions_BODY'
                }
              ]
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

    // ------------------------------------------------------------------------
    // IF DEPLOY EKS
    // ------------------------------------------------------------------------
    if (props.deploymentPlatform == DeploymentPlatform.EKS) {

      new cdk.CfnOutput(this, 'VpcId', {
        value: vpc.vpcId,
        description: 'The ID of the VPC',
        exportName: 'VpcId'
      });

      new cdk.CfnOutput(this, 'ConfigBucketName', {
        value: configBucket.bucketName,
        description: 'The Name of the configuration bucket',
        exportName: 'ConfigBucketName'
      });

      new cdk.CfnOutput(this, 'ConfigBucketArn', {
        value: configBucket.bucketArn,
        description: 'The ARN of the configuration bucket',
        exportName: 'ConfigBucketArn'
      });

      new cdk.CfnOutput(this, 'WafAclArn', {
        value: webAcl.attrArn,
        description: 'The ARN of the WAF ACL',
        exportName: 'WafAclArn'
      });
      
      new cdk.CfnOutput(this, 'LiteLLMRepositoryUrl', {
        value: ecrLitellmRepository.repositoryUri,
        description: 'The URI of the LiteLLM ECR repository',
        exportName: 'LiteLLMRepositoryUrl'
      });
      
      new cdk.CfnOutput(this, 'MiddlewareRepositoryUrl', {
        value: ecrMiddlewareRepository.repositoryUri,
        description: 'The URI of the middleware ECR repository',
        exportName: 'MiddlewareRepositoryUrl'
      });
      
      new cdk.CfnOutput(this, 'DatabaseUrlSecretArn', {
        value: dbUrlSecret.secretArn,
        description: 'The endpoint of the main database',
      });
      
      new cdk.CfnOutput(this, 'DatabaseMiddlewareUrlSecretArn', {
        value: dbMiddlewareUrlSecret.secretArn,
        description: 'The endpoint of the middleware database',
      });
      
      new cdk.CfnOutput(this, 'RedisUrl', {
        value: `redis://${redis.attrPrimaryEndPointAddress}:${redis.attrPrimaryEndPointPort}`,
        description: 'The Redis connection URL',
        exportName: 'RedisUrl'
      });

      new cdk.CfnOutput(this, 'LitellmMasterAndSaltKeySecretArn', {
        value: litellmMasterAndSaltKeySecret.secretArn,
      });

      new cdk.CfnOutput(this, 'DbSecurityGroupId', {
        value: dbSecurityGroup.securityGroupId
      });

      new cdk.CfnOutput(this, 'RedisSecurityGroupId', {
        value: redisSecurityGroup.securityGroupId
      });
    }
    else {
      // Create ECS Cluster
      const cluster = new ecs.Cluster(this, 'LiteLLMCluster', {
        vpc,
        containerInsights: true,
      });

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
          AI21_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'AI21_API_KEY'),
          LANGSMITH_API_KEY: ecs.Secret.fromSecretsManager(litellmOtherSecrets, 'LANGSMITH_API_KEY'),
        },
        environment: {
          LITELLM_CONFIG_BUCKET_NAME: configBucket.bucketName,
          LITELLM_CONFIG_BUCKET_OBJECT_KEY: 'config.yaml',
          UI_USERNAME: "admin",
          REDIS_URL: `redis://${redis.attrPrimaryEndPointAddress}:${redis.attrPrimaryEndPointPort}`,
          LANGSMITH_PROJECT: props.langsmithProject,
          LANGSMITH_DEFAULT_RUN_NAME: props.langsmithDefaultRunName
        }
      });

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
            containerPort: 3000,
            listener: 'Listener',
          },
          {
            containerPort: 4000,
            listener: 'Listener',
          },
        ],
        desiredCount: 1,
        healthCheckGracePeriod: cdk.Duration.seconds(300),
      });

      const listener = fargateService.listeners[0]; // The previously created listener
      const targetGroup = fargateService.targetGroups[0]; // The main target group created

      listener.addAction('BedrockModels', {
        priority: 16,
        conditions: [
          elasticloadbalancingv2.ListenerCondition.pathPatterns(['/bedrock/model/*']),
          elasticloadbalancingv2.ListenerCondition.httpRequestMethods(['POST', 'GET', 'PUT'])
        ],
        action: elasticloadbalancingv2.ListenerAction.forward([targetGroup]),
      });

      // Add additional rules with multiple conditions, all pointing to the same targetGroup
      // OpenAI Paths - Each with unique priority
      listener.addAction('OpenAICompletions', {
        priority: 15,
        conditions: [
          elasticloadbalancingv2.ListenerCondition.pathPatterns(['/v1/chat/completions']),
          elasticloadbalancingv2.ListenerCondition.httpRequestMethods(['POST', 'GET', 'PUT'])
        ],
        action: elasticloadbalancingv2.ListenerAction.forward([targetGroup]),
      });

      listener.addAction('ChatCompletions', {
        priority: 14,
        conditions: [
          elasticloadbalancingv2.ListenerCondition.pathPatterns(['/chat/completions']),
          elasticloadbalancingv2.ListenerCondition.httpRequestMethods(['POST', 'GET', 'PUT'])
        ],
        action: elasticloadbalancingv2.ListenerAction.forward([targetGroup]),
      });

      listener.addAction('ChatHistory', {
        priority: 8,
        conditions: [
          elasticloadbalancingv2.ListenerCondition.pathPatterns(['/chat-history']),
          elasticloadbalancingv2.ListenerCondition.httpRequestMethods(['POST', 'GET', 'PUT'])
        ],
        action: elasticloadbalancingv2.ListenerAction.forward([targetGroup]),
      });

      listener.addAction('BedrockChatHistory', {
        priority: 9,
        conditions: [
          elasticloadbalancingv2.ListenerCondition.pathPatterns(['/bedrock/chat-history']),
          elasticloadbalancingv2.ListenerCondition.httpRequestMethods(['POST', 'GET', 'PUT'])
        ],
        action: elasticloadbalancingv2.ListenerAction.forward([targetGroup]),
      });

      listener.addAction('BedrockLiveliness', {
        priority: 10,
        conditions: [
          elasticloadbalancingv2.ListenerCondition.pathPatterns(['/bedrock/health/liveliness']),
          elasticloadbalancingv2.ListenerCondition.httpRequestMethods(['POST', 'GET', 'PUT'])
        ],
        action: elasticloadbalancingv2.ListenerAction.forward([targetGroup]),
      });

      // More Paths - Each with unique priority
      listener.addAction('SessionIds', {
        priority: 11,
        conditions: [
          elasticloadbalancingv2.ListenerCondition.pathPatterns(['/session-ids']),
          elasticloadbalancingv2.ListenerCondition.httpRequestMethods(['POST', 'GET', 'PUT'])
        ],
        action: elasticloadbalancingv2.ListenerAction.forward([targetGroup]),
      });

      listener.addAction('KeyGenerate', {
        priority: 12,
        conditions: [
          elasticloadbalancingv2.ListenerCondition.pathPatterns(['/key/generate']),
          elasticloadbalancingv2.ListenerCondition.httpRequestMethods(['POST', 'GET', 'PUT'])
        ],
        action: elasticloadbalancingv2.ListenerAction.forward([targetGroup]),
      });

      listener.addAction('UserNew', {
        priority: 13,
        conditions: [
          elasticloadbalancingv2.ListenerCondition.pathPatterns(['/user/new']),
          elasticloadbalancingv2.ListenerCondition.httpRequestMethods(['POST', 'GET', 'PUT'])
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

      

      new cdk.CfnOutput(this, 'LitellmEcsCluster', {
        value: cluster.clusterName,
        description: 'Name of the ECS Cluster'
      });

      new cdk.CfnOutput(this, 'LitellmEcsTask', {
        value: fargateService.service.serviceName,
        description: 'Name of the task service'
      });
    }

    new cdk.CfnOutput(this, 'ServiceURL', {
      value: `https://${props.domainName}`,
    });
  }
}

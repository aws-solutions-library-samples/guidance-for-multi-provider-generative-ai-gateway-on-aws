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
  langsmithApiKey: string,
  langsmithProject: string,
  langsmithDefaultRunName: string,
  deploymentPlatform: DeploymentPlatform

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

    // Create VPC
    const vpc = new ec2.Vpc(this, 'LiteLLMVpc', {
      maxAzs: 2,
      natGateways: 1,
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
      // ════════════════
      // EKS variant
      // ════════════════
      // 1) Create an EKS cluster with defaultCapacity
      // const eksCluster = new eks.Cluster(this, 'LiteLLMEksCluster', {
      //   version: eks.KubernetesVersion.V1_31,
      //   vpc,
      //   defaultCapacity: 2,
      //   kubectlLayer: new KubectlV26Layer(this, 'KubectlLayer')
      // });

      const eksCluster = new eks.Cluster(this, 'HelloEKS', {
        version: eks.KubernetesVersion.V1_31,
        vpc,
        defaultCapacity: 0,
        kubectlLayer: new KubectlV26Layer(this, 'KubectlLayer'),
        albController: {
          version: eks.AlbControllerVersion.V2_8_2,
        },
      });

      // Add a managed nodegroup with specific architecture
      const nodegroup = eksCluster.addNodegroupCapacity('custom-ng', {
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
      

      // 1) Call 'aws sts get-caller-identity' directly in Node.js at synth time
      //    This requires that the "aws" CLI is installed and configured on your machine/environment.
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

      // Optional: Add output to see both mapped roles
      new cdk.CfnOutput(this, 'MappedBaseRole', {
        value: baseRoleArn,
        description: 'The IAM role mapped to system:masters',
      });

      new cdk.CfnOutput(this, 'MappedAssumedRole', {
        value: assumedRoleArn,
        description: 'The assumed role pattern mapped to system:masters',
      });

      // 2) Attach ECS-like policies to the node role
      //    so pods can do the same S3/Bedrock/SageMaker calls ECS tasks had.
      const nodeRole = nodegroup.role;
      
      const ecrPolicyStatement = new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: [
          'ecr:GetDownloadUrlForLayer',
          'ecr:BatchGetImage',
          'ecr:BatchCheckLayerAvailability'
        ],
        principals: [nodeRole]
      });
      
      ecrLitellmRepository.addToResourcePolicy(ecrPolicyStatement);
      ecrMiddlewareRepository.addToResourcePolicy(ecrPolicyStatement);

      // Same as ECS: read config bucket
      nodeRole.addToPrincipalPolicy(new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['s3:GetObject', 's3:ListBucket'],
        resources: [
          configBucket.bucketArn,
          `${configBucket.bucketArn}/*`
        ],
      }));

      // Same as ECS: full S3 access to log bucket
      nodeRole.addToPrincipalPolicy(new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['s3:*'],
        resources: [
          props.logBucketArn,
          `${props.logBucketArn}/*`
        ],
      }));

      // Same as ECS: bedrock:* 
      nodeRole.addToPrincipalPolicy(new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['bedrock:*'],
        resources: ['*'],
      }));

      // Same as ECS: sagemaker:InvokeEndpoint
      nodeRole.addToPrincipalPolicy(new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['sagemaker:InvokeEndpoint'],
        resources: ['*'],
      }));

      nodeRole.addManagedPolicy(
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonEC2ContainerRegistryReadOnly")
      );
      

      // Create a Lambda function to fetch secrets and create K8s secrets
      const secretsFunction = new lambda.Function(this, 'SecretsFunction', {
        runtime: lambda.Runtime.NODEJS_16_X,
        handler: 'index.handler',
        code: lambda.Code.fromInline(`
          const AWS = require('aws-sdk');
          const secretsManager = new AWS.SecretsManager();
          const response = require('cfn-response');

          exports.handler = async (event, context) => {

            // Handle Create/Update/Delete if you wish
            // For simplicity:
            if (event.RequestType === 'Delete') {
              return response.send(event, context, response.SUCCESS);
            }
            try {
              console.log("Event received:", JSON.stringify(event, null, 2));


              // Get database passwords
              const dbSecret = await secretsManager.getSecretValue({ SecretId: event.ResourceProperties.dbSecretArn }).promise();
              const dbMiddlewareSecret = await secretsManager.getSecretValue({ SecretId: event.ResourceProperties.dbMiddlewareSecretArn }).promise();
              
              const dbPassword = JSON.parse(dbSecret.SecretString).password;
              const dbMiddlewarePassword = JSON.parse(dbMiddlewareSecret.SecretString).password;
              
              // Create K8s secret values
              const responseData = {
                DATABASE_URL: \`postgresql://llmproxy:\${dbPassword}@\${event.ResourceProperties.dbEndpoint}:5432/litellm\`,
                LITELLM_MASTER_KEY: 'sk-' + Math.random().toString(36).substring(2),
                LITELLM_SALT_KEY: 'sk-' + Math.random().toString(36).substring(2),
                OPENAI_API_KEY: event.ResourceProperties.openaiApiKey,
                AZURE_OPENAI_API_KEY: event.ResourceProperties.azureOpenAiApiKey,
                AZURE_API_KEY: event.ResourceProperties.azureApiKey,
                ANTHROPIC_API_KEY: event.ResourceProperties.anthropicApiKey,
                GROQ_API_KEY: event.ResourceProperties.groqApiKey,
                COHERE_API_KEY: event.ResourceProperties.cohereApiKey,
                CO_API_KEY: event.ResourceProperties.coApiKey,
                HF_TOKEN: event.ResourceProperties.hfToken,
                HUGGINGFACE_API_KEY: event.ResourceProperties.huggingfaceApiKey,
                DATABRICKS_API_KEY: event.ResourceProperties.databricksApiKey,
                GEMINI_API_KEY: event.ResourceProperties.geminiApiKey,
                CODESTRAL_API_KEY: event.ResourceProperties.codestralApiKey,
                MISTRAL_API_KEY: event.ResourceProperties.mistralApiKey,
                AZURE_AI_API_KEY: event.ResourceProperties.azureAiApiKey,
                NVIDIA_NIM_API_KEY: event.ResourceProperties.nvidiaNimApiKey,
                XAI_API_KEY: event.ResourceProperties.xaiApiKey,
                PERPLEXITYAI_API_KEY: event.ResourceProperties.perplexityaiApiKey,
                GITHUB_API_KEY: event.ResourceProperties.githubApiKey,
                DEEPSEEK_API_KEY: event.ResourceProperties.deepseekApiKey,
                AI21_API_KEY: event.ResourceProperties.ai21ApiKey,
                DATABASE_MIDDLEWARE_URL: \`postgresql://middleware:\${dbMiddlewarePassword}@\${event.ResourceProperties.dbMiddlewareEndpoint}:5432/middleware\`,
              };

              console.log("Final response:", JSON.stringify(responseData, null, 2));

              return response.send(event, context, response.SUCCESS, responseData);

            } catch (error) {
              console.error("Error occurred:", error);
              return response.send(event, context, response.FAILED, { error });
            }
          };
        `),
      });

      // Grant permissions to read secrets
      databaseSecret.grantRead(secretsFunction);
      databaseMiddlewareSecret.grantRead(secretsFunction);

      // Create custom resource using the Lambda
      const secretsCustomResource = new cdk.CustomResource(this, 'SecretsCustomResource', {
        serviceTimeout: cdk.Duration.minutes(2),
        serviceToken: secretsFunction.functionArn,
        properties: {
          dbSecretArn: databaseSecret.secretArn,
          dbMiddlewareSecretArn: databaseMiddlewareSecret.secretArn,
          dbEndpoint: database.instanceEndpoint.hostname,
          dbMiddlewareEndpoint: databaseMiddleware.instanceEndpoint.hostname,
          openaiApiKey: props.openaiApiKey,
          azureOpenAiApiKey: props.azureOpenAiApiKey,
          azureApiKey: props.azureApiKey,
          anthropicApiKey: props.anthropicApiKey,
          groqApiKey: props.groqApiKey,
          cohereApiKey: props.cohereApiKey,
          coApiKey: props.coApiKey,
          hfToken: props.hfToken,
          huggingfaceApiKey: props.huggingfaceApiKey,
          databricksApiKey: props.databricksApiKey,
          geminiApiKey: props.geminiApiKey,
          codestralApiKey: props.codestralApiKey,
          mistralApiKey: props.mistralApiKey,
          azureAiApiKey: props.azureAiApiKey,
          nvidiaNimApiKey: props.nvidiaNimApiKey,
          xaiApiKey: props.xaiApiKey,
          perplexityaiApiKey: props.perplexityaiApiKey,
          githubApiKey: props.githubApiKey,
          deepseekApiKey: props.deepseekApiKey,
          ai21ApiKey: props.ai21ApiKey,
        }
      });

      // Create Kubernetes secrets using the values from custom resource
      const litellmApiKeys = eksCluster.addManifest('LiteLLMApiKeysSecret', {
        apiVersion: 'v1',
        kind: 'Secret',
        metadata: { name: 'litellm-api-keys' },
        stringData: {
          DATABASE_URL: secretsCustomResource.getAtt('DATABASE_URL').toString(),
          LITELLM_MASTER_KEY: secretsCustomResource.getAtt('LITELLM_MASTER_KEY').toString(),
          LITELLM_SALT_KEY: secretsCustomResource.getAtt('LITELLM_SALT_KEY').toString(),
          OPENAI_API_KEY: secretsCustomResource.getAtt('OPENAI_API_KEY').toString(),
          AZURE_OPENAI_API_KEY: secretsCustomResource.getAtt('AZURE_OPENAI_API_KEY').toString(),
          AZURE_API_KEY: secretsCustomResource.getAtt('AZURE_API_KEY').toString(),
          ANTHROPIC_API_KEY: secretsCustomResource.getAtt('ANTHROPIC_API_KEY').toString(),
          GROQ_API_KEY: secretsCustomResource.getAtt('GROQ_API_KEY').toString(),
          COHERE_API_KEY: secretsCustomResource.getAtt('COHERE_API_KEY').toString(),
          CO_API_KEY: secretsCustomResource.getAtt('CO_API_KEY').toString(),
          HF_TOKEN: secretsCustomResource.getAtt('HF_TOKEN').toString(),
          HUGGINGFACE_API_KEY: secretsCustomResource.getAtt('HUGGINGFACE_API_KEY').toString(),
          DATABRICKS_API_KEY: secretsCustomResource.getAtt('DATABRICKS_API_KEY').toString(),
          GEMINI_API_KEY: secretsCustomResource.getAtt('GEMINI_API_KEY').toString(),
          CODESTRAL_API_KEY: secretsCustomResource.getAtt('CODESTRAL_API_KEY').toString(),
          MISTRAL_API_KEY: secretsCustomResource.getAtt('MISTRAL_API_KEY').toString(),
          AZURE_AI_API_KEY: secretsCustomResource.getAtt('AZURE_AI_API_KEY').toString(),
          NVIDIA_NIM_API_KEY: secretsCustomResource.getAtt('NVIDIA_NIM_API_KEY').toString(),
          XAI_API_KEY: secretsCustomResource.getAtt('XAI_API_KEY').toString(),
          PERPLEXITYAI_API_KEY: secretsCustomResource.getAtt('PERPLEXITYAI_API_KEY').toString(),
          GITHUB_API_KEY: secretsCustomResource.getAtt('GITHUB_API_KEY').toString(),
          DEEPSEEK_API_KEY: secretsCustomResource.getAtt('DEEPSEEK_API_KEY').toString(),
          AI21_API_KEY: secretsCustomResource.getAtt('AI21_API_KEY').toString(),
        }
      });

      const middlewareSecrets = eksCluster.addManifest('MiddlewareSecrets', {
        apiVersion: 'v1',
        kind: 'Secret',
        metadata: { name: 'middleware-secrets' },
        stringData: {
          DATABASE_MIDDLEWARE_URL: secretsCustomResource.getAtt('DATABASE_MIDDLEWARE_URL').toString(),
          MASTER_KEY: secretsCustomResource.getAtt('LITELLM_MASTER_KEY').toString(),
        },
      });

      // 5) Create the Deployment with 2 containers
      const deploymentName = 'litellm-deployment';
      const appLabels = { app: 'litellm' };
      // 2. Update your deployment manifest to use the secrets
      const deploymentResource = eksCluster.addManifest('LiteLLMDeployment', {
        apiVersion: 'apps/v1',
        kind: 'Deployment',
        metadata: { name: deploymentName },
        spec: {
          replicas: 1,
          selector: { matchLabels: appLabels },
          template: {
            metadata: { labels: appLabels },
            spec: {
              containers: [
                {
                  name: 'litellm-container',
                  image: `${ecrLitellmRepository.repositoryUri}:${props.liteLLMVersion}`,
                  ports: [{ containerPort: 4000 }],
                  env: [
                    // Non-secret environment variables
                    {
                      name: 'LITELLM_CONFIG_BUCKET_NAME',
                      value: configBucket.bucketName
                    },
                    {
                      name: 'LITELLM_CONFIG_BUCKET_OBJECT_KEY',
                      value: 'config.yaml'
                    },
                    {
                      name: 'UI_USERNAME',
                      value: 'admin'
                    },
                    {
                      name: 'REDIS_URL',
                      value: `redis://${redis.attrPrimaryEndPointAddress}:${redis.attrPrimaryEndPointPort}`
                    },
                    {
                      name: 'LANGSMITH_PROJECT',
                      value: props.langsmithProject
                    },
                    {
                      name: 'LANGSMITH_DEFAULT_RUN_NAME',
                      value: props.langsmithDefaultRunName
                    },
                    {
                      name: 'AWS_REGION',
                      value: cdk.Stack.of(this).region  // Dynamically get the region from the stack
                    },
                    // Secret environment variables
                    {
                      name: 'DATABASE_URL',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'DATABASE_URL'
                        }
                      }
                    },
                    {
                      name: 'LITELLM_MASTER_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'LITELLM_MASTER_KEY'
                        }
                      }
                    },
                    {
                      name: 'UI_PASSWORD',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'LITELLM_MASTER_KEY'
                        }
                      }
                    },
                    {
                      name: 'LITELLM_SALT_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'LITELLM_SALT_KEY'
                        }
                      }
                    },
                    {
                      name: 'OPENAI_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'OPENAI_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'AZURE_OPENAI_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'AZURE_OPENAI_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'AZURE_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'AZURE_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'ANTHROPIC_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'ANTHROPIC_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'GROQ_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'GROQ_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'COHERE_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'COHERE_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'CO_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'CO_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'HF_TOKEN',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'HF_TOKEN'
                        }
                      }
                    },
                    {
                      name: 'HUGGINGFACE_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'HUGGINGFACE_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'DATABRICKS_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'DATABRICKS_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'GEMINI_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'GEMINI_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'CODESTRAL_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'CODESTRAL_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'MISTRAL_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'MISTRAL_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'AZURE_AI_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'AZURE_AI_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'NVIDIA_NIM_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'NVIDIA_NIM_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'XAI_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'XAI_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'PERPLEXITYAI_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'PERPLEXITYAI_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'GITHUB_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'GITHUB_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'DEEPSEEK_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'DEEPSEEK_API_KEY'
                        }
                      }
                    },
                    {
                      name: 'AI21_API_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'litellm-api-keys',
                          key: 'AI21_API_KEY'
                        }
                      }
                    }
                  ],
                  readinessProbe: {
                    httpGet: { path: '/health/liveliness', port: 4000 },
                    initialDelaySeconds: 20,
                    periodSeconds: 10,
                  },
                  livenessProbe: {
                    httpGet: { path: '/health/liveliness', port: 4000 },
                    initialDelaySeconds: 20,
                    periodSeconds: 10,
                  },
                },
                {
                  name: 'middleware-container',
                  image: `${ecrMiddlewareRepository.repositoryUri}:latest`,
                  ports: [{ containerPort: 3000 }],
                  env: [
                    {
                      name: 'OKTA_ISSUER',
                      value: props.oktaIssuer
                    },
                    {
                      name: 'OKTA_AUDIENCE',
                      value: props.oktaAudience
                    },
                    {
                      name: 'AWS_REGION',
                      value: cdk.Stack.of(this).region  // Dynamically get the region from the stack
                    },
                    {
                      name: 'AWS_DEFAULT_REGION',  // Adding both variables
                      value: cdk.Stack.of(this).region
                    },
                    {
                      name: 'DATABASE_MIDDLEWARE_URL',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'middleware-secrets',
                          key: 'DATABASE_MIDDLEWARE_URL'
                        }
                      }
                    },
                    {
                      name: 'MASTER_KEY',
                      valueFrom: {
                        secretKeyRef: {
                          name: 'middleware-secrets',
                          key: 'MASTER_KEY'
                        }
                      }
                    }
                  ],
                  readinessProbe: {
                    httpGet: { path: '/bedrock/health/liveliness', port: 3000 },
                    initialDelaySeconds: 20,
                    periodSeconds: 10,
                  },
                  livenessProbe: {
                    httpGet: { path: '/bedrock/health/liveliness', port: 3000 },
                    initialDelaySeconds: 20,
                    periodSeconds: 10,
                  },
                },
              ],
            },
          },
        },
      });

      // Make sure the deployment waits for secrets to be created
      deploymentResource.node.addDependency(litellmApiKeys);
      deploymentResource.node.addDependency(middlewareSecrets);
      


      // 6) Service (internal). Points to both container ports 3000/4000
      const serviceName = 'litellm-service';
      const service = eksCluster.addManifest('LiteLLMService', {
        apiVersion: 'v1',
        kind: 'Service',
        metadata: { name: serviceName },
        spec: {
          type: 'ClusterIP',
          selector: appLabels,
          ports: [
            { name: 'port4000', port: 4000, targetPort: 4000 },
            { name: 'port3000', port: 3000, targetPort: 3000 },
          ],
        },
      });
      service.node.addDependency(deploymentResource);
    
      // 7) Ingress: ALB with path-based routing + WAF annotation
      const ingressName = 'litellm-ingress';
      // addManifest returns an array of one or more constructs
      const ingressResource = eksCluster.addManifest('LiteLLMIngress', {
        apiVersion: 'networking.k8s.io/v1',
        kind: 'Ingress',
        metadata: {
          name: ingressName,
          annotations: {
            'kubernetes.io/ingress.class': 'alb',
            'alb.ingress.kubernetes.io/listen-ports': '[{"HTTP":80},{"HTTPS":443}]',
            'alb.ingress.kubernetes.io/scheme': 'internet-facing',
            'alb.ingress.kubernetes.io/target-type': 'ip',
            'alb.ingress.kubernetes.io/certificate-arn': props.certificateArn,
            'alb.ingress.kubernetes.io/ssl-policy': 'ELBSecurityPolicy-2016-08',
            'alb.ingress.kubernetes.io/wafv2-acl-arn': webAcl.attrArn, // attach WAF
          },
        },
        spec: {
          ingressClassName: 'alb',
          rules: [
            {
              host: props.domainName,
              http: {
                paths: [
                  {
                    path: '/bedrock/model',
                    pathType: 'Prefix',
                    backend: {
                      service: { name: serviceName, port: { name: 'port3000' } },
                    },
                  },
                  {
                    path: '/v1/chat/completions',
                    pathType: 'Prefix',
                    backend: {
                      service: { name: serviceName, port: { name: 'port3000' } },
                    },
                  },
                  {
                    path: '/chat/completions',
                    pathType: 'Prefix',
                    backend: {
                      service: { name: serviceName, port: { name: 'port3000' } },
                    },
                  },
                  {
                    path: '/chat-history',
                    pathType: 'Prefix',
                    backend: {
                      service: { name: serviceName, port: { name: 'port3000' } },
                    },
                  },
                  {
                    path: '/bedrock/chat-history',
                    pathType: 'Prefix',
                    backend: {
                      service: { name: serviceName, port: { name: 'port3000' } },
                    },
                  },
                  {
                    path: '/bedrock/health/liveliness',
                    pathType: 'Prefix',
                    backend: {
                      service: { name: serviceName, port: { name: 'port3000' } },
                    },
                  },
                  {
                    path: '/session-ids',
                    pathType: 'Prefix',
                    backend: {
                      service: { name: serviceName, port: { name: 'port3000' } },
                    },
                  },
                  {
                    path: '/key/generate',
                    pathType: 'Prefix',
                    backend: {
                      service: { name: serviceName, port: { name: 'port3000' } },
                    },
                  },
                  {
                    path: '/user/new',
                    pathType: 'Prefix',
                    backend: {
                      service: { name: serviceName, port: { name: 'port3000' } },
                    },
                  },
                  {
                    path: '/',
                    pathType: 'Prefix',
                    backend: {
                      service: { name: serviceName, port: { name: 'port4000' } },
                    },
                  },
                ],
              },
            },
          ],
        },
      });
      ingressResource.node.addDependency(service);
      ingressResource.node.addDependency(webAcl);

      // 8) Let DB & Redis allow traffic from EKS nodes
      dbSecurityGroup.addIngressRule(ec2.Peer.ipv4(vpc.vpcCidrBlock), ec2.Port.tcp(5432));
      redisSecurityGroup.addIngressRule(ec2.Peer.ipv4(vpc.vpcCidrBlock), ec2.Port.tcp(6379));

      new cdk.CfnOutput(this, 'WebAclArn', {
        value: webAcl.attrArn,
        description: 'ARN of the WAF Web ACL'
      });

      new route53.ARecord(this, 'LiteLLMDNSRecord', {
        zone: hostedZone,
        recordName: props.domainName, // This creates litellm.mirodrr.people.aws.dev
        target: route53.RecordTarget.fromAlias(
          new route53targets.LoadBalancerTarget(
            elbv2.ApplicationLoadBalancer.fromLookup(this, 'ALBLookup', {
              loadBalancerTags: {
                'ingress.k8s.aws/resource': 'LoadBalancer',
                'ingress.k8s.aws/stack': `default/litellm-ingress`,
              },
            })
          )
        ),
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

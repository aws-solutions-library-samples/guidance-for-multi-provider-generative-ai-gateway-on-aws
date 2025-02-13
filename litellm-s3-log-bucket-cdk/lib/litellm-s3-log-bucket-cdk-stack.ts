import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Tag, Aspects } from 'aws-cdk-lib';

export class LogBucketCdkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);
    Aspects.of(this).add(new Tag('stack-id', this.stackName));
    Aspects.of(this).add(new Tag('project', 'llmgateway'));


    const bucket = new s3.Bucket(this, 'LitellmLogBucket', {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    new cdk.CfnOutput(this, 'LogBucketName', {
      value: bucket.bucketName,
      description: 'The name of the Log S3 bucket'
    });

    new cdk.CfnOutput(this, 'LogBucketArn', {
      value: bucket.bucketArn,
      description: 'The arn of the Log S3 bucket'
    });
  }
}

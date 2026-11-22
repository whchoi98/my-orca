#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { OrcaAttachStack } from '../lib/orca-attach-stack';
import { OrcaStack } from '../lib/orca-stack';

const app = new cdk.App();

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION || 'ap-northeast-2',
};

// -c attachTo=<host stack>: Orca on that stack's existing server and ALB (deploy_orca.sh --attach).
// Otherwise: Orca on its own VPC, ALB and EC2.
const attachTo = app.node.tryGetContext('attachTo');
if (attachTo) {
  new OrcaAttachStack(app, app.node.tryGetContext('stackName') || 'OrcaOnVscodeStack', {
    env,
    description: `Orca on the existing server of ${attachTo} - own CloudFront (+password gate), shared ALB, SSM install`,
  });
} else {
  new OrcaStack(app, app.node.tryGetContext('stackName') || 'OrcaServerStack', {
    env,
    description: 'Orca headless server - CloudFront, ALB (prefix list + secret header), private Graviton EC2',
  });
}

app.synth();

// Pieces both stacks put in front of an orca-serve host:
//   OrcaStack       - its own VPC, ALB and EC2 (bin/app.ts default)
//   OrcaAttachStack - an existing server and ALB, e.g. ec2_vscode's VscodeServerStack
// Each helper adds its resources directly to the given stack with fixed construct IDs, so the
// logical IDs in OrcaStack's template are the same as before these helpers existed.
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as s3assets from 'aws-cdk-lib/aws-s3-assets';
import * as cr from 'aws-cdk-lib/custom-resources';

// orca-ide serve answers the web client (HTTP) and its RPC (WebSocket) on this one port.
export const ORCA_PORT = 6768;
// First-login password setup service (lib/gate/setup_service.py), reached via /__gate/setup.
export const GATE_SETUP_PORT = 6769;

export interface OriginSecret {
  readonly secret: secretsmanager.Secret;
  /** CloudFormation dynamic reference: resolved at deploy time, never written into the template. */
  readonly value: string;
}

/**
 * X-Custom-Secret header value. The CloudFront prefix list admits every CloudFront distribution,
 * not just ours, so this value is the only thing that ties the ALB to this distribution. A random
 * Secrets Manager value replaces one derived from the stack name and account ID, which is guessable.
 */
export function addOriginSecret(stack: cdk.Stack): OriginSecret {
  const secret = new secretsmanager.Secret(stack, 'OriginVerifySecret', {
    description: `${stack.stackName} CloudFront -> ALB X-Custom-Secret header value`,
    generateSecretString: {
      passwordLength: 48,
      excludePunctuation: true,
      includeSpace: false,
    },
    removalPolicy: cdk.RemovalPolicy.DESTROY,
  });
  return { secret, value: secret.secretValue.unsafeUnwrap() };
}

export interface PasswordGate {
  readonly store: cloudfront.KeyValueStore;
  /** lib/gate, installed on the host by install.sh <kvs-arn> <region>. */
  readonly setupAsset: s3assets.Asset;
  readonly associations: cloudfront.FunctionAssociation[];
}

/**
 * Password gate (CloudFront Function + KeyValueStore), like code-server's password page.
 *
 * Orca's own access control is its pairing link; this adds a password in front of the UI, its
 * assets and the WebSocket upgrade. The store holds only a salt, a salted hash and the cookie
 * signing key; nothing secret is in the template. The password comes either from deploy time
 * (set_password.sh) or, if that was skipped, from the first login: the setup page posts to the
 * host's setup service, which checks the one-time code embedded in the pairing link and writes the
 * store (functions can only read it). `hostRole` is the role of the server that runs that service.
 */
export function addPasswordGate(stack: cdk.Stack, hostRole: iam.IRole): PasswordGate {
  const store = new cloudfront.KeyValueStore(stack, 'PasswordGateStore', {
    comment: `${stack.stackName} Orca password gate (salt, hash, cookie key)`,
  });
  const setupAsset = new s3assets.Asset(stack, 'PasswordGateSetupAsset', {
    path: path.join(__dirname, 'gate'),
    exclude: ['__pycache__', '*.pyc'],
  });
  setupAsset.grantRead(hostRole);
  hostRole.addToPrincipalPolicy(new iam.PolicyStatement({
    sid: 'PasswordGateFirstLoginSetup',
    actions: [
      'cloudfront-keyvaluestore:DescribeKeyValueStore',
      'cloudfront-keyvaluestore:GetKey',
      'cloudfront-keyvaluestore:UpdateKeys',
    ],
    resources: [store.keyValueStoreArn],
  }));
  const gateFunction = new cloudfront.Function(stack, 'PasswordGateFunction', {
    runtime: cloudfront.FunctionRuntime.JS_2_0,
    keyValueStore: store,
    code: cloudfront.FunctionCode.fromFile({
      filePath: path.join(__dirname, 'functions', 'password-gate.js'),
    }),
    comment: `${stack.stackName} Orca password gate (viewer request)`,
  });
  return {
    store,
    setupAsset,
    associations: [{ function: gateFunction, eventType: cloudfront.FunctionEventType.VIEWER_REQUEST }],
  };
}

/** CloudFront in front of the ALB; the origin request always carries X-Custom-Secret. */
export function addDistribution(
  stack: cdk.Stack, albDnsName: string, originSecretValue: string, gate?: PasswordGate,
): cloudfront.Distribution {
  const albOrigin = new origins.HttpOrigin(albDnsName, {
    httpPort: 80,
    protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,
    readTimeout: cdk.Duration.seconds(60),
    customHeaders: {
      'X-Custom-Secret': originSecretValue,
    },
  });
  const functionAssociations = gate?.associations;
  return new cloudfront.Distribution(stack, 'CloudFrontDistribution', {
    comment: `Orca server distribution for ${stack.stackName}`,
    defaultBehavior: {
      origin: albOrigin,
      viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
      allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
      // Pass WebSocket upgrade headers and ?orca-client=web through untouched.
      cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
      originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER,
      functionAssociations,
    },
    additionalBehaviors: {
      // Hashed, immutable web client bundles (Cache-Control: immutable from Orca).
      // The gate still runs first: viewer-request functions execute before the cache.
      '/assets/*': {
        origin: albOrigin,
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
        compress: true,
        functionAssociations,
      },
    },
    priceClass: cloudfront.PriceClass.PRICE_CLASS_ALL,
  });
}

export interface OrcaRoutesProps {
  readonly vpc: ec2.IVpc;
  readonly listener: elbv2.IApplicationListener;
  /** The orca-serve host as an ALB target on the given port. */
  readonly targetFor: (port: number) => elbv2.IApplicationLoadBalancerTarget;
  readonly originSecretValue: string;
  readonly gate?: PasswordGate;
  /** Listener rule priorities; another service may already use lower ones on a shared listener. */
  readonly gateSetupPriority?: number;
  readonly orcaPriority?: number;
}

/** Target groups and listener rules: forward only when X-Custom-Secret matches. */
export function addOrcaRoutes(stack: cdk.Stack, props: OrcaRoutesProps): void {
  const orcaTg = new elbv2.ApplicationTargetGroup(stack, 'OrcaTargetGroup', {
    targetGroupName: `${stack.stackName}-TG`,
    vpc: props.vpc,
    port: ORCA_PORT,
    protocol: elbv2.ApplicationProtocol.HTTP,
    targetType: elbv2.TargetType.INSTANCE,
    healthCheck: {
      // Served by Orca's static web client handler without authentication.
      path: '/web-index.html',
      port: String(ORCA_PORT),
      healthyHttpCodes: '200',
      interval: cdk.Duration.seconds(30),
      timeout: cdk.Duration.seconds(5),
      healthyThresholdCount: 2,
      unhealthyThresholdCount: 3,
    },
  });
  orcaTg.addTarget(props.targetFor(ORCA_PORT));

  if (props.gate) {
    const gateSetupTg = new elbv2.ApplicationTargetGroup(stack, 'GateSetupTargetGroup', {
      targetGroupName: `${stack.stackName}-GateTG`,
      vpc: props.vpc,
      port: GATE_SETUP_PORT,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.INSTANCE,
      healthCheck: {
        path: '/__gate/health',
        port: String(GATE_SETUP_PORT),
        healthyHttpCodes: '200',
        interval: cdk.Duration.seconds(30),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3,
      },
    });
    gateSetupTg.addTarget(props.targetFor(GATE_SETUP_PORT));
    // Evaluated before OrcaRule; the CloudFront Function forwards this path only while unset.
    props.listener.addAction('GateSetupRule', {
      priority: props.gateSetupPriority ?? 5,
      conditions: [
        elbv2.ListenerCondition.httpHeader('X-Custom-Secret', [props.originSecretValue]),
        elbv2.ListenerCondition.pathPatterns(['/__gate/setup']),
      ],
      action: elbv2.ListenerAction.forward([gateSetupTg]),
    });
  }

  props.listener.addAction('OrcaRule', {
    priority: props.orcaPriority ?? 10,
    conditions: [
      elbv2.ListenerCondition.httpHeader('X-Custom-Secret', [props.originSecretValue]),
    ],
    action: elbv2.ListenerAction.forward([orcaTg]),
  });
}

export interface PairingInfoProps {
  readonly instanceId: string;
  readonly pairingAddress: string;
  readonly gateEnabled: boolean;
}

/**
 * Pairing link in the stack outputs (custom resource, lib/pairing).
 *
 * orca-serve mints the link on the host after setup, so the deploy waits for setup to finish and
 * reads the link over SSM Run Command. This touches no UserData: adding it to a running stack does
 * not restart the instance. The values are credentials and land in plain text in the stack outputs
 * (anyone with cloudformation:DescribeStacks can read them) and in the SSM command history.
 * -c pairingOutput=false leaves all of this out (returns undefined).
 */
export function addPairingInfo(stack: cdk.Stack, props: PairingInfoProps): cdk.CustomResource | undefined {
  if (stack.node.tryGetContext('pairingOutput') === 'false') {
    return undefined;
  }
  const pairingLogs = new logs.LogGroup(stack, 'PairingInfoLogs', {
    retention: logs.RetentionDays.ONE_WEEK,
    removalPolicy: cdk.RemovalPolicy.DESTROY,
  });
  const pairingCode = lambda.Code.fromAsset(path.join(__dirname, 'pairing'), {
    exclude: ['__pycache__', '*.pyc'],
  });
  const pairingFunction = (id: string, handler: string, timeout: cdk.Duration) =>
    new lambda.Function(stack, id, {
      runtime: lambda.Runtime.PYTHON_3_13,
      architecture: lambda.Architecture.ARM_64,
      code: pairingCode,
      handler,
      timeout,
      logGroup: pairingLogs,
    });
  const onEvent = pairingFunction('PairingInfoOnEvent', 'handler.on_event', cdk.Duration.seconds(30));
  // One poll waits up to ~50 s for its SSM command.
  const isComplete = pairingFunction('PairingInfoIsComplete', 'handler.is_complete', cdk.Duration.seconds(90));
  isComplete.addToRolePolicy(ssmSendCommandStatement(stack, props.instanceId));
  isComplete.addToRolePolicy(ssmReadStatement());
  const pairingProvider = new cr.Provider(stack, 'PairingInfoProvider', {
    onEventHandler: onEvent,
    isCompleteHandler: isComplete,
    queryInterval: cdk.Duration.seconds(30),
    // handler.py gives up (reports "unavailable") at 40 min; CloudFormation's own limit is 60.
    totalTimeout: cdk.Duration.minutes(50),
    logGroup: pairingLogs,
  });
  return new cdk.CustomResource(stack, 'PairingInfo', {
    serviceToken: pairingProvider.serviceToken,
    resourceType: 'Custom::OrcaPairingInfo',
    properties: {
      InstanceId: props.instanceId,
      PairingAddress: props.pairingAddress,
      GateEnabled: String(props.gateEnabled),
      // deploy_orca.sh passes a timestamp so every deploy re-reads the current link.
      Refresh: String(stack.node.tryGetContext('pairingRefresh') ?? 'initial'),
    },
  });
}

/** PairingWebLink / PairingCode / GateSetupCode outputs (read by deploy_orca.sh). */
export function addPairingOutputs(stack: cdk.Stack, pairingInfo: cdk.CustomResource, gateEnabled: boolean): void {
  new cdk.CfnOutput(stack, 'PairingWebLink', {
    value: pairingInfo.getAttString('PairingWebLink'),
    description: 'Open in a browser: access password setup or login, then pairing. A credential - do not share',
  });
  new cdk.CfnOutput(stack, 'PairingCode', {
    value: pairingInfo.getAttString('PairingCode'),
    description: 'orca://pair code for the Orca connect screen (Pairing URL or code). A credential - do not share',
  });
  if (gateEnabled) {
    new cdk.CfnOutput(stack, 'GateSetupCode', {
      value: pairingInfo.getAttString('GateSetupCode'),
      description: 'One-time code for the first-login access password page (consumed once the password is set)',
    });
  }
}

/** ssm:SendCommand limited to one instance and the AWS-RunShellScript document. */
export function ssmSendCommandStatement(stack: cdk.Stack, instanceId: string): iam.PolicyStatement {
  return new iam.PolicyStatement({
    actions: ['ssm:SendCommand'],
    resources: [
      `arn:${stack.partition}:ec2:${stack.region}:${stack.account}:instance/${instanceId}`,
      `arn:${stack.partition}:ssm:${stack.region}::document/AWS-RunShellScript`,
    ],
  });
}

export function ssmReadStatement(): iam.PolicyStatement {
  return new iam.PolicyStatement({
    // Neither action supports resource-level permissions.
    actions: ['ssm:DescribeInstanceInformation', 'ssm:GetCommandInvocation'],
    resources: ['*'],
  });
}

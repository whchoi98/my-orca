import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as elbv2_targets from 'aws-cdk-lib/aws-elasticloadbalancingv2-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as cr from 'aws-cdk-lib/custom-resources';
import { Construct } from 'constructs';
import {
  GATE_SETUP_PORT, ORCA_PORT,
  addDistribution, addOrcaRoutes, addOriginSecret, addPairingInfo, addPairingOutputs, addPasswordGate,
  ssmReadStatement, ssmSendCommandStatement,
} from './orca-front-door';

/** The server and ALB Orca joins; deploy_orca.sh --attach looks these up from the host stack. */
interface HostResources {
  readonly stackName: string;
  readonly instanceId: string;
  readonly vpcId: string;
  readonly listenerArn: string;
  readonly albDnsName: string;
  readonly albSecurityGroupId: string;
  readonly instanceSecurityGroupId: string;
  readonly roleName: string;
  readonly user: string;
}

/**
 * Orca on an existing server behind an existing ALB, e.g. ec2_vscode's VscodeServerStack:
 *
 *   new CloudFront (+ password gate) -> host ALB listener: rule on Orca's own X-Custom-Secret
 *     -> host EC2 :6768 (orca-serve), :6769 (first-login setup)
 *
 * The host stack is never updated: everything here is added beside it (listener rules, security
 * group rules, an IAM policy on the host role) and removed with this stack. Orca itself is
 * installed over SSM Run Command (lib/host), not UserData, so the host keeps running throughout.
 * Its other services keep their own CloudFront and header value: the ALB tells the two
 * distributions apart by the header value alone, on the same listener.
 */
export class OrcaAttachStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);
    cdk.Tags.of(this).add('Project', 'my-orca');

    const host = this.hostResources();
    cdk.Tags.of(this).add('OrcaHostStack', host.stackName);

    const orcaVersion = new cdk.CfnParameter(this, 'OrcaVersion', {
      type: 'String',
      default: '1.4.269',
      allowedPattern: '^[0-9]+\\.[0-9]+\\.[0-9]+$',
      description: 'Orca release to install (github.com/stablyai/orca/releases, without the leading v); '
        + 'changing it upgrades the host in place',
    });

    // -------------------------------------------------------
    // Host resources (imported, never modified in their own stack)
    // -------------------------------------------------------
    const vpc = ec2.Vpc.fromLookup(this, 'HostVpc', { vpcId: host.vpcId });
    const albSg = ec2.SecurityGroup.fromSecurityGroupId(this, 'HostAlbSecurityGroup', host.albSecurityGroupId, {
      mutable: false,
    });
    const instanceSg = ec2.SecurityGroup.fromSecurityGroupId(
      this, 'HostInstanceSecurityGroup', host.instanceSecurityGroupId,
    );
    const hostRole = iam.Role.fromRoleName(this, 'HostRole', host.roleName);
    const listener = elbv2.ApplicationListener.fromApplicationListenerAttributes(this, 'HostListener', {
      listenerArn: host.listenerArn,
      securityGroup: albSg,
    });

    // Standalone SecurityGroupIngress resources in this stack, removed with it.
    instanceSg.addIngressRule(albSg, ec2.Port.tcp(ORCA_PORT), `Orca from ALB (${this.stackName})`);
    const passwordGateEnabled = this.node.tryGetContext('passwordGate') !== 'false';
    if (passwordGateEnabled) {
      instanceSg.addIngressRule(albSg, ec2.Port.tcp(GATE_SETUP_PORT), `Orca password setup from ALB (${this.stackName})`);
    }

    // -------------------------------------------------------
    // Front door: Orca's own header secret, password gate and CloudFront
    // -------------------------------------------------------
    const originSecret = addOriginSecret(this);
    const gate = passwordGateEnabled ? addPasswordGate(this, hostRole) : undefined;
    const distribution = addDistribution(this, host.albDnsName, originSecret.value, gate);
    const pairingAddress = `wss://${distribution.distributionDomainName}`;

    addOrcaRoutes(this, {
      vpc,
      listener,
      targetFor: (port) => new elbv2_targets.InstanceIdTarget(host.instanceId, port),
      originSecretValue: originSecret.value,
      gate,
      gateSetupPriority: numberContext(this, 'gateSetupRulePriority', 5),
      orcaPriority: numberContext(this, 'orcaRulePriority', 10),
    });

    // -------------------------------------------------------
    // Install orca-serve on the host (custom resource, lib/host)
    // -------------------------------------------------------
    const hostDir = path.join(__dirname, 'host');
    const installLogs = new logs.LogGroup(this, 'HostInstallLogs', {
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    const hostCode = lambda.Code.fromAsset(hostDir, { exclude: ['__pycache__', '*.pyc'] });
    const installFunction = (fnId: string, handler: string) =>
      new lambda.Function(this, fnId, {
        runtime: lambda.Runtime.PYTHON_3_13,
        architecture: lambda.Architecture.ARM_64,
        code: hostCode,
        handler,
        timeout: cdk.Duration.seconds(30),
        logGroup: installLogs,
      });
    const onEvent = installFunction('HostInstallOnEvent', 'handler.on_event');
    const isComplete = installFunction('HostInstallIsComplete', 'handler.is_complete');
    for (const fn of [onEvent, isComplete]) {
      fn.addToRolePolicy(ssmSendCommandStatement(this, host.instanceId));
      fn.addToRolePolicy(ssmReadStatement());
    }
    const installProvider = new cr.Provider(this, 'HostInstallProvider', {
      onEventHandler: onEvent,
      isCompleteHandler: isComplete,
      queryInterval: cdk.Duration.seconds(15),
      // install_orca.sh's own limit (SSM executionTimeout) is 30 min.
      totalTimeout: cdk.Duration.minutes(40),
      logGroup: installLogs,
    });
    const install = new cdk.CustomResource(this, 'HostInstall', {
      serviceToken: installProvider.serviceToken,
      resourceType: 'Custom::OrcaHostInstall',
      properties: {
        InstanceId: host.instanceId,
        User: host.user,
        OrcaVersion: orcaVersion.valueAsString,
        PairingAddress: pairingAddress,
        Region: this.region,
        GateStoreArn: gate?.store.keyValueStoreArn ?? '',
        GateBundleUrl: gate?.setupAsset.s3ObjectUrl ?? '',
        // Re-runs the (idempotent) install whenever a host script changes, so the host and the
        // uninstall script the stack would run on delete never drift apart unnoticed.
        ScriptSha256: ['install_orca.sh', 'uninstall_orca.sh']
          .reduce((hash, name) => hash.update(fs.readFileSync(path.join(hostDir, name))), crypto.createHash('sha256'))
          .digest('hex'),
      },
    });
    // The host role's new policy (S3 bundle, KeyValueStore) must exist before the install runs.
    install.node.addDependency(hostRole);

    const pairingInfo = addPairingInfo(this, {
      instanceId: host.instanceId,
      pairingAddress,
      gateEnabled: gate !== undefined,
    });
    pairingInfo?.node.addDependency(install);

    // -------------------------------------------------------
    // Outputs: same keys as OrcaStack, so get_pairing_url.sh / set_password.sh / cleanup.sh work
    // with --stack-name. The header secret itself is never output.
    // -------------------------------------------------------
    new cdk.CfnOutput(this, 'HostStack', {
      value: host.stackName,
      description: 'Stack of the server Orca runs on (not modified; deleting this stack only removes Orca)',
    });
    new cdk.CfnOutput(this, 'CloudFrontURL', {
      value: `https://${distribution.distributionDomainName}`,
      description: 'CloudFront URL (Orca web client; pair with PairingWebLink or get_pairing_url.sh)',
    });
    new cdk.CfnOutput(this, 'PairingAddress', {
      value: pairingAddress,
      description: 'Address Orca embeds in pairing links',
    });
    if (pairingInfo) {
      addPairingOutputs(this, pairingInfo, gate !== undefined);
    }
    new cdk.CfnOutput(this, 'PublicALBEndpoint', {
      value: `http://${host.albDnsName}`,
      description: 'Host ALB (shared; reachable only through CloudFront when the host SG allows only the prefix list)',
    });
    new cdk.CfnOutput(this, 'InstanceId', { value: host.instanceId, description: 'Host EC2 instance running orca-serve' });
    new cdk.CfnOutput(this, 'OriginSecretArn', {
      value: originSecret.secret.secretArn,
      description: 'Secrets Manager ARN of the X-Custom-Secret header value (Orca distribution only)',
    });
    if (gate) {
      new cdk.CfnOutput(this, 'PasswordGateStoreArn', {
        value: gate.store.keyValueStoreArn,
        description: 'CloudFront KeyValueStore ARN for the password gate (set with set_password.sh)',
      });
      new cdk.CfnOutput(this, 'PasswordGateSetupBundle', {
        value: gate.setupAsset.s3ObjectUrl,
        description: 'First-login setup service bundle (reinstall: unzip, then install.sh <kvs-arn> <region>)',
      });
    }
    new cdk.CfnOutput(this, 'SSMAccess', {
      value: `aws ssm start-session --target ${host.instanceId} --region ${this.region}`,
      description: 'SSM Session Manager access command',
    });
    new cdk.CfnOutput(this, 'Architecture', {
      value: `CloudFront (HTTPS) -> ${host.stackName} ALB (CloudFront prefix list SG; this stack's X-Custom-Secret, `
        + `else 403) -> host EC2 (orca-serve HTTP/WS:${ORCA_PORT})`,
      description: 'Network Architecture',
    });
  }

  private hostResources(): HostResources {
    const need = (key: string, pattern: RegExp): string => {
      const value = this.node.tryGetContext(key);
      if (typeof value !== 'string' || !pattern.test(value)) {
        throw new Error(`OrcaAttachStack: -c ${key}=<value> is missing or malformed `
          + '(deploy_orca.sh --attach <host-stack> fills it in)');
      }
      return value;
    };
    return {
      stackName: need('attachTo', /^[A-Za-z][A-Za-z0-9-]*$/),
      instanceId: need('hostInstanceId', /^i-[0-9a-f]+$/),
      vpcId: need('hostVpcId', /^vpc-[0-9a-f]+$/),
      listenerArn: need('hostListenerArn', /^arn:aws[a-z-]*:elasticloadbalancing:.+:listener\/app\//),
      albDnsName: need('hostAlbDnsName', /^[A-Za-z0-9.-]+\.elb\.amazonaws\.com$/),
      albSecurityGroupId: need('hostAlbSecurityGroupId', /^sg-[0-9a-f]+$/),
      instanceSecurityGroupId: need('hostInstanceSecurityGroupId', /^sg-[0-9a-f]+$/),
      roleName: need('hostRoleName', /^[\w+=,.@-]+$/),
      user: String(this.node.tryGetContext('hostUser') ?? 'ec2-user'),
    };
  }
}

function numberContext(scope: Construct, key: string, fallback: number): number {
  const value = scope.node.tryGetContext(key);
  return value === undefined ? fallback : Number(value);
}

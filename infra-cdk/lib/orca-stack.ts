import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as elbv2_targets from 'aws-cdk-lib/aws-elasticloadbalancingv2-targets';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';
import {
  GATE_SETUP_PORT, ORCA_PORT,
  addDistribution, addOrcaRoutes, addOriginSecret, addPairingInfo, addPairingOutputs, addPasswordGate,
} from './orca-front-door';

/** Orca on its own VPC, ALB and EC2. For an existing server, see OrcaAttachStack. */
export class OrcaStack extends cdk.Stack {
  public readonly vpc: ec2.IVpc;
  public readonly alb: elbv2.ApplicationLoadBalancer;
  public readonly distribution: cloudfront.Distribution;
  public readonly instance: ec2.Instance;

  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);
    cdk.Tags.of(this).add('Project', 'my-orca');

    // -------------------------------------------------------
    // Parameters
    // -------------------------------------------------------
    const arm64InstanceTypes = [
      'r6g.xlarge', 'r6g.2xlarge',
      'r7g.xlarge', 'r7g.2xlarge',
      'm6g.xlarge', 'm6g.2xlarge',
      'm7g.xlarge', 'm7g.2xlarge',
      't4g.xlarge', 't4g.2xlarge',
    ];
    const x86InstanceTypes = [
      'r7i.xlarge', 'm7i.xlarge', 'm7i.2xlarge',
      't3.xlarge', 't3.2xlarge',
    ];

    const instanceType = new cdk.CfnParameter(this, 'InstanceType', {
      type: 'String',
      default: 'r6g.xlarge',
      allowedValues: [...arm64InstanceTypes, ...x86InstanceTypes],
      description: 'EC2 instance type for the Orca server (ARM64 Graviton recommended)',
    });

    const orcaVersion = new cdk.CfnParameter(this, 'OrcaVersion', {
      type: 'String',
      default: '1.4.269',
      allowedPattern: '^[0-9]+\\.[0-9]+\\.[0-9]+$',
      description: 'Orca release to install (github.com/stablyai/orca/releases, without the leading v)',
    });

    const cloudFrontPrefixListId = new cdk.CfnParameter(this, 'CloudFrontPrefixListId', {
      type: 'String',
      allowedPattern: '^pl-[0-9a-f]+$',
      description: 'CloudFront origin-facing managed prefix list ID (com.amazonaws.global.cloudfront.origin-facing)',
    });

    const vpcName = new cdk.CfnParameter(this, 'VpcName', {
      type: 'String',
      default: 'orca-vpc',
      description: 'Name tag for the new VPC (ignored when an existing VPC is used)',
    });

    // -------------------------------------------------------
    // VPC: existing (context) or new
    // -------------------------------------------------------
    const useExistingVpc = this.node.tryGetContext('useExistingVpc') === 'true';
    if (useExistingVpc) {
      this.vpc = ec2.Vpc.fromLookup(this, 'VPC', { vpcId: this.node.tryGetContext('vpcId') || '' });
    } else {
      const vpc = new ec2.Vpc(this, 'VPC', {
        ipAddresses: ec2.IpAddresses.cidr(this.node.tryGetContext('vpcCidr') || '10.253.0.0/16'),
        maxAzs: 2,
        natGateways: 1,
        subnetConfiguration: [
          { cidrMask: 24, name: 'Public', subnetType: ec2.SubnetType.PUBLIC },
          { cidrMask: 24, name: 'Private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
        ],
      });
      cdk.Tags.of(vpc).add('Name', vpcName.valueAsString);
      this.vpc = vpc;
    }

    // -------------------------------------------------------
    // Security Groups
    //   ALB SG : inbound 80 only from the CloudFront origin-facing prefix list
    //   EC2 SG : inbound 6768 only from the ALB SG
    // -------------------------------------------------------
    const albSg = new ec2.SecurityGroup(this, 'ALBSecurityGroup', {
      vpc: this.vpc,
      securityGroupName: `${this.stackName}-ALB-SG`,
      description: 'ALB SG - CloudFront origin-facing only',
      // The ALB only ever talks to the Orca target; egress is added below.
      allowAllOutbound: false,
    });

    new ec2.CfnSecurityGroupIngress(this, 'ALBIngressFromCloudFront', {
      groupId: albSg.securityGroupId,
      ipProtocol: 'tcp',
      fromPort: 80,
      toPort: 80,
      sourcePrefixListId: cloudFrontPrefixListId.valueAsString,
      description: 'HTTP from CloudFront origin-facing only',
    });

    const ec2Sg = new ec2.SecurityGroup(this, 'EC2SecurityGroup', {
      vpc: this.vpc,
      securityGroupName: `${this.stackName}-Orca-SG`,
      description: 'Orca EC2 SG - ALB traffic only',
      allowAllOutbound: true,
    });
    ec2Sg.addIngressRule(albSg, ec2.Port.tcp(ORCA_PORT), 'Orca from ALB');
    albSg.addEgressRule(ec2Sg, ec2.Port.tcp(ORCA_PORT), 'ALB to Orca');
    const passwordGateEnabled = this.node.tryGetContext('passwordGate') !== 'false';
    if (passwordGateEnabled) {
      ec2Sg.addIngressRule(albSg, ec2.Port.tcp(GATE_SETUP_PORT), 'Password setup service from ALB');
      albSg.addEgressRule(ec2Sg, ec2.Port.tcp(GATE_SETUP_PORT), 'ALB to password setup service');
    }

    // -------------------------------------------------------
    // SSM VPC Endpoints (skip if context skipVpcEndpoints=true)
    // -------------------------------------------------------
    if (this.node.tryGetContext('skipVpcEndpoints') !== 'true') {
      const ssmSg = new ec2.SecurityGroup(this, 'SSMSecurityGroup', {
        vpc: this.vpc,
        description: 'SSM VPC Endpoints SG - HTTPS from VPC CIDR',
        allowAllOutbound: true,
      });
      ssmSg.addIngressRule(ec2.Peer.ipv4(this.vpc.vpcCidrBlock), ec2.Port.tcp(443), 'HTTPS from VPC CIDR');

      const endpoints: Array<[string, ec2.InterfaceVpcEndpointAwsService]> = [
        ['SSMEndpoint', ec2.InterfaceVpcEndpointAwsService.SSM],
        ['SSMMessagesEndpoint', ec2.InterfaceVpcEndpointAwsService.SSM_MESSAGES],
        ['EC2MessagesEndpoint', ec2.InterfaceVpcEndpointAwsService.EC2_MESSAGES],
      ];
      for (const [endpointId, service] of endpoints) {
        new ec2.InterfaceVpcEndpoint(this, endpointId, {
          vpc: this.vpc,
          service,
          subnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
          securityGroups: [ssmSg],
          privateDnsEnabled: true,
        });
      }
    }

    // -------------------------------------------------------
    // Origin verification secret (X-Custom-Secret), see addOriginSecret
    // -------------------------------------------------------
    const originSecret = addOriginSecret(this);

    // -------------------------------------------------------
    // IAM Role for EC2 (SSM + CloudWatch + Bedrock invoke for coding agents)
    // -------------------------------------------------------
    // IAM is global: a suffix (e.g. -us-west-2) avoids clashing with the same stack in another region
    const roleNameSuffix = this.node.tryGetContext('roleNameSuffix') ?? '';
    const ec2Role = new iam.Role(this, 'EC2Role', {
      roleName: `${this.stackName}-Orca-Role${roleNameSuffix}`,
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('CloudWatchAgentServerPolicy'),
      ],
      description: 'Orca server EC2 role - SSM + CloudWatch + Bedrock invoke',
    });
    ec2Role.addToPolicy(new iam.PolicyStatement({
      sid: 'BedrockInvokeForCodingAgents',
      actions: [
        'bedrock:InvokeModel',
        'bedrock:InvokeModelWithResponseStream',
        'bedrock:Converse',
        'bedrock:ConverseStream',
        'bedrock:CountTokens',
        'bedrock:ListFoundationModels',
        'bedrock:GetFoundationModel',
        'bedrock:ListInferenceProfiles',
        'bedrock:GetInferenceProfile',
      ],
      resources: ['*'],
    }));

    // -------------------------------------------------------
    // CloudFront origin (ALB) — created before the instance so its domain
    // can be baked into the Orca pairing address
    // -------------------------------------------------------
    this.alb = new elbv2.ApplicationLoadBalancer(this, 'PublicALB', {
      loadBalancerName: `${this.stackName}-ALB`,
      vpc: this.vpc,
      internetFacing: true,
      securityGroup: albSg,
      // WebSocket sessions stay open for hours; Orca also heartbeats every 15s.
      idleTimeout: cdk.Duration.seconds(3600),
      dropInvalidHeaderFields: true,
    });

    // Password gate (CloudFront Function + KeyValueStore), see addPasswordGate.
    // Disable: -c passwordGate=false.
    const gate = passwordGateEnabled ? addPasswordGate(this, ec2Role) : undefined;
    const gateStore = gate?.store;
    const gateAsset = gate?.setupAsset;
    this.distribution = addDistribution(this, this.alb.loadBalancerDnsName, originSecret.value, gate);

    const pairingAddress = `wss://${this.distribution.distributionDomainName}`;

    // -------------------------------------------------------
    // EC2 Instance (Private Subnet)
    // -------------------------------------------------------
    // AMI architecture follows the InstanceType parameter, resolved at deploy time
    const isArm64 = new cdk.CfnCondition(this, 'IsArm64Instance', {
      expression: cdk.Fn.conditionOr(
        ...arm64InstanceTypes.map((t) => cdk.Fn.conditionEquals(instanceType.valueAsString, t)),
      ),
    });
    // cachedInContext pins the AMI ID in cdk.context.json. Without it every deploy re-reads the
    // "latest" SSM parameter, and a newly published AMI would replace the instance (and its EBS
    // volume with the user's repos). Refresh deliberately with: npx cdk context --clear
    const al2023Arm64 = ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.ARM_64, cachedInContext: true });
    const al2023X86 = ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.X86_64, cachedInContext: true });
    const al2023: ec2.IMachineImage = {
      getImage: (scope) => ({
        imageId: cdk.Token.asString(cdk.Fn.conditionIf(
          isArm64.logicalId,
          al2023Arm64.getImage(scope).imageId,
          al2023X86.getImage(scope).imageId,
        )),
        osType: ec2.OperatingSystemType.LINUX,
        userData: ec2.UserData.forLinux(),
      }),
    };

    // Setup runs from a systemd oneshot unit rather than straight from cloud-init.
    // cloud-init runs user data once per instance, but an SSM patch association
    // (AWS-RunPatchBaseline, RebootIfNeeded) can reboot a fresh instance a few
    // minutes into setup and the script would never resume. The unit re-runs
    // setup.sh on every boot until it writes the done marker, so each step must
    // be re-runnable.
    const setupScript = [
      '#!/bin/bash',
      'set -euxo pipefail',
      'exec > >(tee -a /var/log/user-data.log) 2>&1',
      'export HOME=/root',
      'echo "Starting Orca Server setup at $(date)"',
      'ARCH=$(uname -m)',
      '',
      '# System update',
      'dnf update -y --allowerasing',
      'dnf install -y --allowerasing curl jq tar gzip unzip wget git tmux python3 python3-pip',
      '# bedrock-agentcore needs Python >= 3.10; AL2023 python3 is 3.9, so do not fail the setup on it',
      'pip3 install boto3 click || echo "[WARN] pip install boto3/click failed"',
      'pip3 install bedrock-agentcore || echo "[WARN] bedrock-agentcore needs Python >= 3.10 (AL2023 python3 is 3.9)"',
      '',
      '# Development tools (required for native npm modules on ARM64)',
      'dnf groupinstall -y "Development Tools" || dnf install -y gcc gcc-c++ make || echo "[WARN] Dev tools install failed"',
      '',
      '# Node.js 22 LTS (Node 20 reached end of life in 2026-04)',
      'curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - || true',
      'dnf install -y nodejs || true',
      'if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 22 ]; then',
      '  curl -fsSL https://fnm.vercel.app/install | bash',
      '  export FNM_DIR="/root/.local/share/fnm"',
      '  export PATH="$FNM_DIR:$PATH"',
      '  eval "$(fnm env)"',
      '  fnm install 22 && fnm use 22',
      '  ln -sf "$(which node)" /usr/local/bin/node',
      '  ln -sf "$(which npm)" /usr/local/bin/npm',
      '  ln -sf "$(which npx)" /usr/local/bin/npx',
      'fi',
      'echo "Node.js version: $(node -v)"',
      '',
      '# AWS CLI v2',
      'cd /tmp',
      'rm -rf aws awscliv2.zip',
      'curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o awscliv2.zip',
      'unzip -oq awscliv2.zip && ./aws/install --update && rm -rf aws awscliv2.zip',
      '',
      '# SSM Plugin',
      'if [ "$ARCH" = "aarch64" ]; then',
      '  dnf install -y https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_arm64/session-manager-plugin.rpm',
      'else',
      '  dnf install -y https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm',
      'fi',
      '',
      '# Docker',
      'dnf install -y docker',
      'systemctl enable docker && systemctl start docker',
      'usermod -aG docker ec2-user',
      '',
      '# uv package manager (for ec2-user: ~/.local/bin)',
      'sudo -u ec2-user -H bash -c "set -o pipefail; curl -fsSL https://astral.sh/uv/install.sh | sh" || echo "[WARN] uv install failed"',
      '',
      '# Kiro CLI',
      'cd /home/ec2-user',
      'if [ "$ARCH" = "aarch64" ]; then',
      '  KIRO_ZIP="kirocli-aarch64-linux.zip"',
      'else',
      '  KIRO_ZIP="kirocli-x86_64-linux.zip"',
      'fi',
      'rm -rf kirocli kirocli.zip',
      'if curl --proto "=https" --tlsv1.2 -sSf "https://desktop-release.q.us-east-1.amazonaws.com/latest/${KIRO_ZIP}" -o kirocli.zip; then',
      '  unzip -oq kirocli.zip',
      '  if [ -d "kirocli/bin" ]; then',
      '    chmod +x kirocli/bin/*',
      '    cp kirocli/bin/* /usr/local/bin/',
      '    echo "kiro-cli installed successfully"',
      '  fi',
      '  rm -rf kirocli kirocli.zip',
      'else',
      '  echo "[WARN] kiro-cli download failed"',
      'fi',
      '',
      '# Claude Code CLI: native installer as ec2-user (~/.local/bin, auto-updates without sudo)',
      'CLAUDE_INSTALL="set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash"',
      'sudo -u ec2-user -H bash -c "$CLAUDE_INSTALL" || {',
      '  echo "[WARN] Claude Code CLI install failed, retrying..."',
      '  sleep 10',
      '  sudo -u ec2-user -H bash -c "$CLAUDE_INSTALL" || echo "[WARN] Claude Code CLI install failed after retry"',
      '}',
      '',
      '# Codex CLI: user npm prefix (~/.npm-global), same layout as ec2_vscode codex-cli-setup',
      'sudo -u ec2-user -H bash -c \'npm install --global --prefix "$HOME/.npm-global" @openai/codex@latest\' || echo "[WARN] Codex CLI install failed"',
      'CODEX_PATH_LINE=\'export PATH="$HOME/.npm-global/bin:$PATH"\'',
      'grep -Fqx -- "$CODEX_PATH_LINE" /home/ec2-user/.bashrc || printf \'\\n# Codex CLI user installation\\n%s\\n\' "$CODEX_PATH_LINE" >> /home/ec2-user/.bashrc',
      '',
      '# CloudWatch agent',
      'cd /tmp',
      'rm -f amazon-cloudwatch-agent.rpm',
      'if [ "$ARCH" = "aarch64" ]; then',
      '  wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/arm64/latest/amazon-cloudwatch-agent.rpm || true',
      'else',
      '  wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm || true',
      'fi',
      '[ -f amazon-cloudwatch-agent.rpm ] && rpm -U --replacepkgs ./amazon-cloudwatch-agent.rpm || true',
      'rm -f amazon-cloudwatch-agent.rpm',
      '',
      '# ec2_vscode helper scripts (claude-code-setup, kiro-cli-setup, codex-cli-setup)',
      '[ -d /home/ec2-user/ec2_vscode ] || sudo -u ec2-user -H git clone --depth 1 https://github.com/whchoi98/ec2_vscode.git /home/ec2-user/ec2_vscode || echo "[WARN] ec2_vscode clone failed"',
      '',
      '# ---------------- Orca ----------------',
      '# Runtime deps from the orca-ide RPM. xdotool and xclip are not in the AL2023',
      '# repositories; they are only used by desktop control (orca computer) and file',
      '# clipboard copy, so the RPM is installed with --nodeps below.',
      'dnf install -y gtk3 libnotify nss libXScrnSaver libXtst xdg-utils at-spi2-core libuuid alsa-lib python3-gobject xorg-x11-server-Xvfb dbus-tools',
      `ORCA_VERSION="${orcaVersion.valueAsString}"`,
      'if [ "$ARCH" = "aarch64" ]; then ORCA_RPM_ARCH=aarch64; else ORCA_RPM_ARCH=x86_64; fi',
      'if [ "$(rpm -q --qf "%{VERSION}" orca-ide 2>/dev/null || true)" != "$ORCA_VERSION" ]; then',
      '  curl -fL --retry 3 -o /tmp/orca-ide.rpm "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/orca-ide-${ORCA_VERSION}.${ORCA_RPM_ARCH}.rpm"',
      '  rpm -Uvh --nodeps /tmp/orca-ide.rpm',
      '  rm -f /tmp/orca-ide.rpm',
      'fi',
      'sudo -u ec2-user -H /usr/bin/orca-ide --version',
      '',
      '# A user manager for ec2-user lets Orca put each terminal in its own systemd user scope.',
      'EC2_UID=$(id -u ec2-user)',
      'loginctl enable-linger ec2-user',
      'install -d -m 755 /etc/orca',
      "cat > /etc/orca/serve.env <<'ENVEOF'",
      '# orca-serve.service environment. Edit, then: sudo systemctl restart orca-serve',
      '# Address embedded in pairing links (the CloudFront domain of this stack).',
      `ORCA_PAIRING_ADDRESS=${pairingAddress}`,
      `AWS_REGION=${this.region}`,
      'ORCA_TELEMETRY_DISABLED=1',
      '# Agents started from Orca chat inherit this environment (it does not read ~/.bashrc).',
      '# CLAUDE_CODE_USE_BEDROCK=1',
      'ENVEOF',
      'cat > /etc/systemd/system/orca-serve.service <<UNITEOF',
      '[Unit]',
      'Description=Orca headless server (orca-ide serve)',
      'Wants=network-online.target user@${EC2_UID}.service',
      'After=network-online.target user@${EC2_UID}.service',
      'StartLimitIntervalSec=900',
      'StartLimitBurst=5',
      '',
      '[Service]',
      'Type=simple',
      'User=ec2-user',
      'WorkingDirectory=/home/ec2-user',
      'EnvironmentFile=/etc/orca/serve.env',
      'Environment=PATH=/home/ec2-user/.local/bin:/home/ec2-user/.npm-global/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin',
      'Environment=XDG_RUNTIME_DIR=/run/user/${EC2_UID}',
      'Environment=ORCA_USER_DATA_PATH=/home/ec2-user/.config/orca',
      '# Not orca serve service install: that unit adds --no-pairing, and this release has no',
      '# orca pair command, so the pairing link printed at start is the only way to pair.',
      '# No --supervise either: supervised serve hides the pairing link when stdout is not a',
      '# TTY (journald), so systemd Restart= takes over restarts.',
      `ExecStart=/usr/bin/orca-ide serve --port ${ORCA_PORT} --bind 0.0.0.0 --pairing-address \\\${ORCA_PAIRING_ADDRESS}`,
      'Restart=on-failure',
      'RestartSec=10',
      'TimeoutStopSec=90',
      '# The terminal daemon outlives orca serve restarts, as in the upstream service unit.',
      'KillMode=process',
      '',
      '[Install]',
      'WantedBy=multi-user.target',
      'UNITEOF',
      'systemctl daemon-reload && systemctl enable orca-serve && systemctl restart orca-serve',
      '',
      ...(gateStore && gateAsset ? [
        '# Password gate first-login setup service (CDK asset: lib/gate)',
        `/usr/local/bin/aws s3 cp --region ${this.region} "${gateAsset.s3ObjectUrl}" /tmp/orca-gate.zip`,
        'rm -rf /opt/orca-gate-src && mkdir -p /opt/orca-gate-src',
        'unzip -oq /tmp/orca-gate.zip -d /opt/orca-gate-src && rm -f /tmp/orca-gate.zip',
        `bash /opt/orca-gate-src/install.sh "${gateStore.keyValueStoreArn}" "${this.region}"`,
        '',
      ] : []),
      '# Done: orca-bootstrap.service is skipped on later boots',
      'touch /var/lib/orca-bootstrap/done',
      'echo "Orca Server setup completed at $(date)"',
    ];

    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      'set -euxo pipefail',
      'install -d -m 700 /opt/orca-bootstrap',
      'install -d -m 755 /var/lib/orca-bootstrap',
      "cat > /opt/orca-bootstrap/setup.sh <<'SETUP_EOF'",
      ...setupScript,
      'SETUP_EOF',
      'chmod 700 /opt/orca-bootstrap/setup.sh',
      "cat > /etc/systemd/system/orca-bootstrap.service <<'UNIT_EOF'",
      '[Unit]',
      'Description=Orca Server setup (re-runs on each boot until done)',
      'Wants=network-online.target',
      'After=network-online.target cloud-final.service',
      'ConditionPathExists=!/var/lib/orca-bootstrap/done',
      'StartLimitIntervalSec=1h',
      'StartLimitBurst=5',
      '',
      '[Service]',
      'Type=oneshot',
      'ExecStart=/opt/orca-bootstrap/setup.sh',
      'TimeoutStartSec=0',
      'Restart=on-failure',
      'RestartSec=60',
      '',
      '[Install]',
      'WantedBy=multi-user.target',
      'UNIT_EOF',
      'systemctl daemon-reload',
      'systemctl enable orca-bootstrap.service',
      '# --no-block: the unit is ordered after cloud-final, which is running this script',
      'systemctl start --no-block orca-bootstrap.service',
    );

    this.instance = new ec2.Instance(this, 'OrcaServer', {
      instanceName: `${this.stackName}-Orca-Server`,
      vpc: this.vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
      instanceType: new ec2.InstanceType(instanceType.valueAsString),
      machineImage: al2023,
      securityGroup: ec2Sg,
      role: ec2Role,
      userData,
      // No requireImdsv2: AL2023 AMIs already default to IMDSv2-only with hop limit 2,
      // and the CDK launch template would drop the hop limit Docker containers need.
      blockDevices: [
        {
          deviceName: '/dev/xvda',
          volume: ec2.BlockDeviceVolume.ebs(100, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
          }),
        },
      ],
    });

    // -------------------------------------------------------
    // ALB listener: default 403, forward only when X-Custom-Secret matches
    // -------------------------------------------------------
    const listener = this.alb.addListener('Listener80', {
      port: 80,
      protocol: elbv2.ApplicationProtocol.HTTP,
      // open defaults to true and adds 0.0.0.0/0:80 to albSg, bypassing the
      // CloudFront origin-facing prefix list rule (ALBIngressFromCloudFront)
      open: false,
      defaultAction: elbv2.ListenerAction.fixedResponse(403, {
        contentType: 'text/plain',
        messageBody: 'Access Denied',
      }),
    });

    addOrcaRoutes(this, {
      vpc: this.vpc,
      listener,
      targetFor: (port) => new elbv2_targets.InstanceTarget(this.instance, port),
      originSecretValue: originSecret.value,
      gate,
    });

    // Pairing link in the stack outputs, see addPairingInfo
    const pairingInfo = addPairingInfo(this, {
      instanceId: this.instance.instanceId,
      pairingAddress,
      gateEnabled: gate !== undefined,
    });

    // -------------------------------------------------------
    // Outputs (the header secret itself is never output)
    // -------------------------------------------------------
    new cdk.CfnOutput(this, 'VPCId', { value: this.vpc.vpcId, description: 'VPC ID' });

    new cdk.CfnOutput(this, 'CloudFrontURL', {
      value: `https://${this.distribution.distributionDomainName}`,
      description: 'CloudFront URL (Orca web client; pair with PairingWebLink or get_pairing_url.sh)',
      exportName: `${this.stackName}-CloudFront-URL`,
    });

    new cdk.CfnOutput(this, 'PairingAddress', {
      value: pairingAddress,
      description: 'Address Orca embeds in pairing links',
    });

    if (pairingInfo) {
      addPairingOutputs(this, pairingInfo, gate !== undefined);
    }

    new cdk.CfnOutput(this, 'PublicALBEndpoint', {
      value: `http://${this.alb.loadBalancerDnsName}`,
      description: 'Public ALB DNS Name (CloudFront prefix list only; direct access blocked)',
    });

    new cdk.CfnOutput(this, 'InstanceId', {
      value: this.instance.instanceId,
      description: 'Orca Server EC2 Instance ID',
      exportName: `${this.stackName}-Instance-ID`,
    });

    new cdk.CfnOutput(this, 'PrivateIP', { value: this.instance.instancePrivateIp, description: 'Orca Server Private IP' });

    new cdk.CfnOutput(this, 'EC2RoleName', { value: ec2Role.roleName, description: 'Orca Server EC2 IAM Role name' });

    new cdk.CfnOutput(this, 'OriginSecretArn', {
      value: originSecret.secret.secretArn,
      description: 'Secrets Manager ARN of the X-Custom-Secret header value',
    });

    if (gateStore) {
      new cdk.CfnOutput(this, 'PasswordGateStoreArn', {
        value: gateStore.keyValueStoreArn,
        description: 'CloudFront KeyValueStore ARN for the password gate (set with set_password.sh)',
      });
    }
    if (gateStore && gateAsset) {
      new cdk.CfnOutput(this, 'PasswordGateSetupBundle', {
        value: gateAsset.s3ObjectUrl,
        description: 'First-login setup service bundle (reinstall: unzip, then install.sh <kvs-arn> <region>)',
      });
    }

    new cdk.CfnOutput(this, 'SSMAccess', {
      value: `aws ssm start-session --target ${this.instance.instanceId} --region ${this.region}`,
      description: 'SSM Session Manager access command',
    });

    new cdk.CfnOutput(this, 'Architecture', {
      value: `CloudFront (HTTPS) -> ALB (HTTP:80, CloudFront prefix list SG + X-Custom-Secret) -> Orca EC2 (HTTP/WS:${ORCA_PORT}, private subnet)`,
      description: 'Network Architecture',
    });
  }
}

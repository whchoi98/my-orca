"""Tests for deploy_orca.sh and the guide it shares with deploy_orca_tf.sh (deploy_guide.sh).
Run: python3 -I test/deploy_test.py

The script runs from a temp dir with fake aws, curl, npm, npx and node on PATH. The fake npx
records the cdk command instead of deploying. Nothing here reaches AWS.
"""
import json
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VPC = "vpc-0123456789abcdef0"
SMALL_VPC = "vpc-0123456789abcdef1"
OTHER_VPC = "vpc-0123456789abcdef2"
ONE_ZONE_VPC = "vpc-0123456789abcdef3"
NO_PRIVATE_VPC = "vpc-0123456789abcdef4"
ENDPOINTS = "vpce-0123456789abcdef0\tvpce-0123456789abcdef1\tvpce-0123456789abcdef2"

FAKE_AWS = r"""#!/bin/bash
echo "$*" >> "$FAKE_DIR/aws-calls"
all="$*"
case "$1 $2" in
    "sts get-caller-identity")
        [[ "$all" == *"--query Account"* ]] && echo 123456789012 || echo "arn:aws:iam::123456789012:user/tester" ;;
    "cloudformation describe-stacks")
        if [[ "$all" == *"--stack-name CDKToolkit"* ]] || [[ "$all" == *"--stack-name Host "* ]]; then exit 0; fi
        if [[ "$all" != *"--query"* ]]; then
            [ -n "${FAKE_STACK:-}" ] || exit 255
            exit 0
        fi
        if [[ "$all" == *"ParameterKey=='InstanceType'"* ]]; then printf '%s\n' "${FAKE_CURRENT:-}"
        elif [[ "$all" == *"OutputKey=='CloudFrontURL'"* ]]; then echo "https://example.test"
        elif [[ "$all" == *"OutputKey=='PairingCode'"* ]]; then echo "unavailable"
        else echo "None"
        fi ;;
    "cloudformation list-stack-resources")
        if [[ "$all" == *"AWS::EC2::VPCEndpoint"* ]]; then printf '%b' "${FAKE_OWNED:-}"
        elif [[ "$all" == *"AWS::EC2::Instance"* ]]; then echo "i-0123456789abcdef0"
        elif [[ "$all" == *"::Listener"* ]]; then echo "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:listener/app/host/0123456789abcdef/0123456789abcdef"
        else echo "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/host/0123456789abcdef"
        fi ;;
    "ec2 describe-managed-prefix-lists") echo "pl-0123456789abcdef0" ;;
    "iam get-role") exit 254 ;;
    "iam get-instance-profile") echo "host-role" ;;
    "ec2 describe-instances") printf '%s\t%s\t%s\t%s\n' "__VPC__" "sg-0123456789abcdef0" arm64 "arn:aws:iam::123456789012:instance-profile/host-profile" ;;
    "elbv2 describe-load-balancers") printf '%s\t%s\n' "host-alb.example.test" "sg-0123456789abcdef1" ;;
    "elbv2 describe-listeners") printf '80\tHTTP\n' ;;
    "ec2 describe-security-group-rules"|"elbv2 describe-rules") ;;
    "ssm describe-instance-information") echo Online ;;
    "cloudfront-keyvaluestore get-key") exit 254 ;;
    "ec2 describe-vpcs") cat "$FAKE_DIR/vpcs.json" ;;
    "ec2 describe-subnets"|"ec2 describe-route-tables")
        vpc=$(grep -oE 'Values=vpc-[0-9a-f]+' <<<"$all" | head -n 1)
        cat "$FAKE_DIR/${2#describe-}-${vpc#Values=}.json" ;;
    "ec2 describe-vpc-endpoints") echo "${FAKE_ENDPOINTS:-}" ;;
    "ec2 describe-instance-type-offerings")
        wanted=$(grep -oE 'Name=instance-type,Values=[^ ]+' <<<"$all" | sed 's/.*Values=//' | tr ',' ' ')
        for type in $wanted; do
            [[ " ${FAKE_NOT_OFFERED:-} " == *" $type "* ]] || echo "$type"
        done ;;
    "ec2 describe-instance-types") echo "${FAKE_CUSTOM_ARCH:-x86_64}" ;;
    *) echo "unexpected aws call: $all" >&2; exit 99 ;;
esac
""".replace("__VPC__", VPC)

FAKE_CURL = r"""#!/bin/bash
url="${@: -1}"
case "$url" in
    */releases/latest) echo "{\"tag_name\": \"v1.4.270\"}" ;;
    */releases/tags/v*)
        tag="${url##*/releases/tags/v}"
        echo "{\"assets\": [{\"name\": \"orca-ide-$tag.aarch64.rpm\"}, {\"name\": \"orca-ide-$tag.x86_64.rpm\"}]}" ;;
    *) exit 22 ;;
esac
"""

FAKE_NPX = r"""#!/bin/bash
echo "$*" >> "$FAKE_DIR/npx-calls"
"""


def subnet(number, zone, public=False, name="", tags=None):
    return {"SubnetId": f"subnet-0123456789abcdef{number}", "AvailabilityZone": f"ap-northeast-2{zone}",
            "MapPublicIpOnLaunch": public, "Tags": [{"Key": "Name", "Value": name}] + (tags or [])}


def write_vpc_fixture(directory):
    """Two VPCs. The first has every kind of subnet the classification tells apart; the second
    has one public subnet and nothing else, so it cannot take the deployment."""
    (directory / "vpcs.json").write_text(json.dumps({"Vpcs": [
        {"VpcId": VPC, "CidrBlock": "10.0.0.0/16", "Tags": [{"Key": "Name", "Value": "lab-vpc"}]},
        {"VpcId": SMALL_VPC, "CidrBlock": "172.31.0.0/16", "IsDefault": True},
    ]}))
    (directory / f"subnets-{VPC}.json").write_text(json.dumps({"Subnets": [
        subnet(1, "a", public=True, name="pub-a"),           # public: assigns public addresses
        subnet(2, "b", name="pub-b"),                        # public: its route table goes to an IGW
        subnet(3, "a", name="priv-a"),                       # private: default route to a NAT gateway
        subnet(4, "b", name="priv-b"),                       # private: main table, default route to a TGW
        subnet(5, "a", name="iso-a"),                        # isolated: no way out
        subnet(6, "a", public=True, name="tagged", tags=[{"Key": "aws-cdk:subnet-type", "Value": "Isolated"}]),
        subnet(7, "a", public=True, name="pub-a2"),          # public, but zone a already has one for the ALB
    ]}))
    (directory / f"route-tables-{VPC}.json").write_text(json.dumps({"RouteTables": [
        {"Associations": [{"SubnetId": "subnet-0123456789abcdef2"}],
         "Routes": [{"GatewayId": "local", "DestinationCidrBlock": "10.0.0.0/16"},
                    {"GatewayId": "igw-0123456789abcdef0", "DestinationCidrBlock": "0.0.0.0/0"}]},
        {"Associations": [{"SubnetId": "subnet-0123456789abcdef3"}],
         "Routes": [{"NatGatewayId": "nat-0123456789abcdef0", "DestinationCidrBlock": "0.0.0.0/0"}]},
        {"Associations": [{"SubnetId": "subnet-0123456789abcdef5"}],
         "Routes": [{"GatewayId": "local", "DestinationCidrBlock": "10.0.0.0/16"}]},
        {"Associations": [{"Main": True}],
         "Routes": [{"TransitGatewayId": "tgw-0123456789abcdef0", "DestinationCidrBlock": "0.0.0.0/0"}]},
    ]}))
    (directory / f"subnets-{SMALL_VPC}.json").write_text(json.dumps({"Subnets": [subnet(8, "a", public=True, name="only")]}))
    (directory / f"route-tables-{SMALL_VPC}.json").write_text(json.dumps({"RouteTables": []}))
    # Public subnets in one Availability Zone only (an ALB needs two), with a private subnet.
    (directory / f"subnets-{ONE_ZONE_VPC}.json").write_text(json.dumps({"Subnets": [
        subnet("a", "a", public=True, name="pub-1"), subnet("b", "a", public=True, name="pub-2"), subnet("c", "a", name="priv")]}))
    (directory / f"route-tables-{ONE_ZONE_VPC}.json").write_text(json.dumps({"RouteTables": [
        {"Associations": [{"SubnetId": "subnet-0123456789abcdefc"}],
         "Routes": [{"NatGatewayId": "nat-0123456789abcdef1", "DestinationCidrBlock": "0.0.0.0/0"}]}]}))
    # Public subnets in two zones, but the only other subnet is isolated: nowhere to put the server.
    (directory / f"subnets-{NO_PRIVATE_VPC}.json").write_text(json.dumps({"Subnets": [
        subnet("d", "a", public=True, name="pub-a"), subnet("e", "b", public=True, name="pub-b"), subnet("f", "a", name="iso")]}))
    (directory / f"route-tables-{NO_PRIVATE_VPC}.json").write_text(json.dumps({"RouteTables": []}))


class DeployScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        for name in ("deploy_orca.sh", "deploy_guide.sh"):
            shutil.copy(ROOT / name, self.tmp / name)
        (self.tmp / "infra-cdk").mkdir()
        write_vpc_fixture(self.tmp)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, text in (("aws", FAKE_AWS), ("curl", FAKE_CURL), ("npx", FAKE_NPX),
                           ("npm", "#!/bin/bash\n"), ("node", "#!/bin/bash\n")):
            path = bin_dir / name
            path.write_text(text)
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        self.env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(self.tmp), "FAKE_DIR": str(self.tmp)}

    def run_script(self, *args, stdin="", **env):
        e = dict(self.env)
        e.update(env)
        return subprocess.run(["/bin/bash", str(self.tmp / "deploy_orca.sh"), *args],
                              input=stdin, capture_output=True, text=True, env=e, timeout=60)

    def lines(self, name):
        path = self.tmp / name
        return path.read_text().splitlines() if path.exists() else []

    def cdk_deploy(self):
        calls = [c for c in self.lines("npx-calls") if c.startswith("cdk deploy")]
        self.assertEqual(len(calls), 1, calls)
        return calls[0]

    def asked_aws(self, needle):
        return any(needle in c for c in self.lines("aws-calls"))

    # ---------------- new dedicated stack ----------------
    def test_yes_deploys_the_defaults_without_questions(self):
        r = self.run_script("--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        cdk = self.cdk_deploy()
        self.assertIn("cdk deploy OrcaServerStack ", cdk)
        self.assertIn("--parameters InstanceType=r6g.xlarge ", cdk)
        self.assertIn("--parameters VpcName=orca-vpc ", cdk)
        self.assertIn("--parameters OrcaVersion=1.4.270 ", cdk)
        self.assertNotIn("useExistingVpc", cdk)
        self.assertNotIn("skipVpcEndpoints", cdk)
        self.assertFalse(self.asked_aws("describe-vpcs"))
        self.assertNotIn("[VPC]", r.stdout)

    def test_guide_existing_vpc_and_a_type_from_the_menu(self):
        # region default, VPC: existing, 1st VPC, type: 9th, no password, yes
        r = self.run_script(stdin="\n2\n1\n9\n\ny\n", FAKE_ENDPOINTS=ENDPOINTS)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        cdk = self.cdk_deploy()
        self.assertIn(f"-c useExistingVpc=true -c vpcId={VPC} ", cdk)
        # The VPC already has SSM endpoints: a second set would clash on private DNS.
        self.assertIn("-c skipVpcEndpoints=true ", cdk)
        self.assertIn("--parameters InstanceType=t4g.xlarge ", cdk)
        shown = [" ".join(line.split()) for line in r.stdout.splitlines()]
        for line in ("1) vpc-0123456789abcdef0 10.0.0.0/16 lab-vpc", "2) vpc-0123456789abcdef1 172.31.0.0/16 (이름 없음) [기본 VPC]",
                     "subnet-0123456789abcdef1 ap-northeast-2a 퍼블릭 pub-a", "subnet-0123456789abcdef2 ap-northeast-2b 퍼블릭 pub-b",
                     "subnet-0123456789abcdef7 ap-northeast-2a 퍼블릭 pub-a2",
                     "subnet-0123456789abcdef3 ap-northeast-2a 프라이빗 priv-a", "subnet-0123456789abcdef4 ap-northeast-2b 프라이빗 priv-b",
                     "subnet-0123456789abcdef5 ap-northeast-2a 격리 iso-a", "subnet-0123456789abcdef6 ap-northeast-2a 격리 tagged",
                     f"VPC: 기존 VPC {VPC}", "SSM 엔드포인트: 만들지 않음", "인스턴스: t4g.xlarge"):
            self.assertIn(line, shown)

    def test_guide_existing_vpc_without_endpoints_gets_them(self):
        r = self.run_script(stdin="\n2\n1\n\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("skipVpcEndpoints", self.cdk_deploy())
        self.assertIn("SSM 엔드포인트: 새로 만듦", r.stdout)

    def test_guide_new_vpc_with_a_name(self):
        r = self.run_script(stdin="\n1\nlab-net\n\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        cdk = self.cdk_deploy()
        self.assertIn("--parameters VpcName=lab-net ", cdk)
        self.assertIn("--parameters InstanceType=r6g.xlarge ", cdk)
        self.assertNotIn("useExistingVpc", cdk)
        self.assertFalse(self.asked_aws("describe-vpcs"))

    def test_guide_goes_back_when_the_vpc_cannot_be_used(self):
        # existing, 2nd VPC (one public subnet only), then new VPC with the default name
        r = self.run_script(stdin="\n2\n2\n1\n\n\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("가용 영역 둘 이상의 퍼블릭 서브넷이 필요합니다 (지금 1개 영역)", r.stdout)
        self.assertIn("EC2를 둘 프라이빗 서브넷", r.stdout)
        self.assertNotIn("useExistingVpc", self.cdk_deploy())

    def test_guide_takes_a_vpc_id_and_refuses_one_that_is_not_listed(self):
        r = self.run_script(stdin=f"\n2\n{OTHER_VPC}\n2\n{VPC}\n\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("목록에 없는 값입니다", r.stdout)
        self.assertIn(f"vpcId={VPC} ", self.cdk_deploy())

    def test_guide_refuses_a_type_outside_the_list(self):
        # new VPC, default name, then a type the stack does not take, then the 3rd of the list
        r = self.run_script(stdin="\n1\n\nc5.large\n0\n99\n3\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("c5.large 은 이 스택이 받는 목록에 없습니다", r.stdout)
        # This stack takes no other type, so 0 (custom) is not offered and counts as a wrong number, like 99.
        self.assertNotIn("직접 입력", r.stdout)
        self.assertEqual(r.stdout.count("목록의 번호를 입력합니다"), 2)
        self.assertIn("--parameters InstanceType=r7g.xlarge ", self.cdk_deploy())

    def test_guide_refuses_a_type_the_region_does_not_offer(self):
        r = self.run_script(stdin="\n1\n\n\n7\n\ny\n", FAKE_NOT_OFFERED="r6g.xlarge m6g.xlarge")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("r6g.xlarge 은 ap-northeast-2 리전에서 제공하지 않습니다", r.stdout)
        self.assertRegex(r.stdout, r"5\) m6g\.xlarge +ARM64 Graviton, 4 vCPU, 16GB  \(이 리전에서 제공하지 않음\)")
        self.assertIn("--parameters InstanceType=m7g.xlarge ", self.cdk_deploy())

    def test_guide_region_by_number_and_by_code(self):
        r = self.run_script(stdin="9\n1\n\n\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(self.asked_aws("--region us-west-2"))
        (self.tmp / "aws-calls").unlink()
        (self.tmp / "npx-calls").unlink()
        r = self.run_script(stdin="tokyo\n99\nme-central-1\n1\n\n\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.count("목록의 번호나 리전 코드"), 2)
        self.assertTrue(self.asked_aws("--region me-central-1"))

    def test_options_skip_their_questions(self):
        # Region, VPC and type are given: only the password prompt and the confirmation are left.
        r = self.run_script("--region", "us-west-2", "--vpc-id", VPC, "--instance-type", "m7g.xlarge", stdin="\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for title in ("[리전]", "[VPC]", "[인스턴스 타입]"):
            self.assertNotIn(title, r.stdout)
        cdk = self.cdk_deploy()
        self.assertIn(f"vpcId={VPC} ", cdk)
        self.assertIn("--parameters InstanceType=m7g.xlarge ", cdk)
        self.assertTrue(self.asked_aws("--region us-west-2"))

    def test_vpc_id_is_checked_before_the_deploy(self):
        r = self.run_script("--vpc-id", SMALL_VPC, "--yes")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("쓸 수 없습니다", r.stdout + r.stderr)
        self.assertEqual(self.lines("npx-calls"), [])

    def test_vpc_needs_two_public_zones_and_a_private_subnet(self):
        r = self.run_script("--vpc-id", ONE_ZONE_VPC, "--yes")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("가용 영역 둘 이상의 퍼블릭 서브넷이 필요합니다 (지금 1개 영역)", r.stdout)
        self.assertNotIn("EC2를 둘 프라이빗 서브넷", r.stdout)
        r = self.run_script("--vpc-id", NO_PRIVATE_VPC, "--yes")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("EC2를 둘 프라이빗 서브넷", r.stdout)
        self.assertNotIn("가용 영역 둘 이상", r.stdout)
        self.assertEqual(self.lines("npx-calls"), [])

    def test_vpc_id_finds_existing_endpoints_by_itself(self):
        r = self.run_script("--vpc-id", VPC, "--yes", FAKE_ENDPOINTS=ENDPOINTS)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("-c skipVpcEndpoints=true ", self.cdk_deploy())
        # No endpoint: the AWS CLI answers with nothing, or with None.
        for answer in ("", "None"):
            with self.subTest(answer):
                (self.tmp / "npx-calls").unlink()
                r = self.run_script("--vpc-id", VPC, "--yes", FAKE_ENDPOINTS=answer)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertNotIn("skipVpcEndpoints", self.cdk_deploy())

    def test_instance_type_outside_the_list_stops_before_the_deploy(self):
        r = self.run_script("--instance-type", "c5.large", "--yes")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("c5.large 은 이 스택이 받는 목록에 없습니다", r.stderr)
        self.assertIn("t3.2xlarge", r.stderr)
        self.assertEqual(self.lines("npx-calls"), [])

    # ---------------- a stack that is already deployed ----------------
    def test_existing_stack_on_its_own_vpc_keeps_its_settings(self):
        r = self.run_script("--yes", FAKE_STACK="1", FAKE_CURRENT=f"m7g.xlarge\tlab-vpc\t{VPC}",
                            FAKE_OWNED=f"AWS::EC2::VPC\\t{VPC}\\nAWS::EC2::VPCEndpoint\\tvpce-0123456789abcdef0\\n", FAKE_ENDPOINTS=ENDPOINTS)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        cdk = self.cdk_deploy()
        self.assertIn("--parameters InstanceType=m7g.xlarge ", cdk)
        self.assertIn("--parameters VpcName=lab-vpc ", cdk)
        self.assertNotIn("useExistingVpc", cdk)
        # Its own endpoints stay: skipping them now would delete them.
        self.assertNotIn("skipVpcEndpoints", cdk)
        # An existing stack keeps its Orca version unless one is given.
        self.assertNotIn("OrcaVersion", cdk)
        self.assertIn("스택이 만든 VPC 유지", r.stdout)

    def test_existing_stack_built_without_endpoints_stays_without(self):
        r = self.run_script("--yes", FAKE_STACK="1", FAKE_CURRENT=f"r6g.xlarge\torca-vpc\t{VPC}", FAKE_OWNED=f"AWS::EC2::VPC\\t{VPC}\\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("-c skipVpcEndpoints=true ", self.cdk_deploy())

    def test_existing_stack_on_an_existing_vpc_keeps_that_vpc(self):
        r = self.run_script("--yes", FAKE_STACK="1", FAKE_CURRENT=f"t4g.2xlarge\torca-vpc\t{VPC}",
                            FAKE_OWNED="AWS::EC2::VPCEndpoint\\tvpce-0123456789abcdef0\\n", FAKE_ENDPOINTS=ENDPOINTS)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        cdk = self.cdk_deploy()
        self.assertIn(f"-c useExistingVpc=true -c vpcId={VPC} ", cdk)
        self.assertNotIn("skipVpcEndpoints", cdk)
        self.assertIn("--parameters InstanceType=t4g.2xlarge ", cdk)
        self.assertIn("기존 VPC 유지", r.stdout)
        # Nothing is looked up again: the stack already says where it is.
        self.assertFalse(self.asked_aws("describe-subnets"))
        self.assertFalse(self.asked_aws("describe-vpc-endpoints"))

    def test_existing_stack_refuses_another_vpc(self):
        own = {"FAKE_STACK": "1", "FAKE_CURRENT": f"r6g.xlarge\torca-vpc\t{VPC}", "FAKE_OWNED": f"AWS::EC2::VPC\\t{VPC}\\n"}
        r = self.run_script("--vpc-id", OTHER_VPC, "--yes", **own)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("스택이 만든 VPC", r.stderr)
        borrowed = {"FAKE_STACK": "1", "FAKE_CURRENT": f"r6g.xlarge\torca-vpc\t{VPC}", "FAKE_OWNED": ""}
        r = self.run_script("--vpc-id", OTHER_VPC, "--yes", **borrowed)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(f"기존 VPC {VPC} 에 배포되어 있습니다", r.stderr)
        self.assertEqual(self.lines("npx-calls"), [])
        # Naming the VPC it is already in is fine.
        r = self.run_script("--vpc-id", VPC, "--yes", **borrowed)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"vpcId={VPC} ", self.cdk_deploy())

    def test_existing_stack_takes_a_new_type_when_asked(self):
        current = {"FAKE_STACK": "1", "FAKE_CURRENT": f"m7g.xlarge\tlab-vpc\t{VPC}", "FAKE_OWNED": f"AWS::EC2::VPC\\t{VPC}\\n"}
        r = self.run_script("--instance-type", "m7g.2xlarge", "--yes", **current)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("--parameters InstanceType=m7g.2xlarge ", self.cdk_deploy())
        (self.tmp / "npx-calls").unlink()
        # Interactive: no VPC question, and the menu offers the current type as the default.
        r = self.run_script(stdin="\n\n\ny\n", **current)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("[VPC]", r.stdout)
        self.assertRegex(r.stdout, r"7\) m7g\.xlarge +ARM64 Graviton, 4 vCPU, 16GB  \(기본값\)")
        self.assertIn("--parameters InstanceType=m7g.xlarge ", self.cdk_deploy())

    def test_stack_without_resources_is_set_up_like_a_new_one(self):
        # A stack that failed on its first deploy exists, but has no VPC to keep.
        r = self.run_script(stdin="\n2\n1\n\n\ny\n", FAKE_STACK="1", FAKE_CURRENT="None\tNone\tNone")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"vpcId={VPC} ", self.cdk_deploy())

    # ---------------- attach ----------------
    def test_attach_is_not_asked_about_a_vpc_or_a_type(self):
        r = self.run_script("--attach", "Host", "--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        cdk = self.cdk_deploy()
        self.assertIn("cdk deploy OrcaOnVscodeStack ", cdk)
        self.assertIn("-c attachTo=Host ", cdk)
        self.assertNotIn("InstanceType", cdk)
        self.assertFalse(self.asked_aws("describe-vpcs"))
        self.assertFalse(self.asked_aws("describe-instance-type-offerings"))
        (self.tmp / "aws-calls").unlink()
        (self.tmp / "npx-calls").unlink()
        # Interactive: the region is the only choice.
        r = self.run_script("--attach", "Host", stdin="3\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("[VPC]", r.stdout)
        self.assertNotIn("[인스턴스 타입]", r.stdout)
        self.assertTrue(self.asked_aws("--region ap-northeast-3"))

    # ---------------- the guide and the stack agree ----------------
    def test_guide_lists_exactly_the_types_the_stack_takes(self):
        stack = (ROOT / "infra-cdk" / "lib" / "orca-stack.ts").read_text()
        arm = re.findall(r"'([a-z0-9]+\.[a-z0-9]+)'", stack[stack.index("const arm64InstanceTypes = ["):stack.index("const x86InstanceTypes = [")])
        x86 = re.findall(r"'([a-z0-9]+\.[a-z0-9]+)'", stack[stack.index("const x86InstanceTypes = ["):stack.index("const instanceType = new")])
        self.assertEqual(len(arm), 10)
        self.assertEqual(len(x86), 5)
        script = 'source "$1"; for t in "${GUIDE_INSTANCE_TYPES[@]}"; do echo "${t%%:*} $(guide_instance_arch ap-northeast-2 "${t%%:*}")"; done'
        r = subprocess.run(["/bin/bash", "-c", script, "-", str(ROOT / "deploy_guide.sh")],
                           capture_output=True, text=True, env=self.env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split("\n")[:-1], [f"{t} aarch64" for t in arm] + [f"{t} x86_64" for t in x86])
        # The list answers the architecture: the EC2 API is only asked about types outside it.
        self.assertFalse(self.asked_aws("describe-instance-types"))

    def test_architecture_of_a_type_outside_the_list(self):
        script = 'source "$1"; guide_instance_arch ap-northeast-2 "$2"'
        for kind, env, expected in (("c7g.xlarge", {"FAKE_CUSTOM_ARCH": "arm64"}, "aarch64"),
                                    ("c7i.xlarge", {"FAKE_CUSTOM_ARCH": "i386\tx86_64"}, "x86_64"),
                                    # The API wins over the name: a1 is Graviton without a g in its name.
                                    ("a1.xlarge", {"FAKE_CUSTOM_ARCH": "arm64"}, "aarch64"),
                                    ("z1g.xlarge", {"FAKE_CUSTOM_ARCH": "x86_64"}, "x86_64"),
                                    # When the API does not answer, the name decides.
                                    ("c8gd.xlarge", {"FAKE_CUSTOM_ARCH": "None"}, "aarch64"),
                                    ("c5.xlarge", {"FAKE_CUSTOM_ARCH": "None"}, "x86_64")):
            with self.subTest(kind):
                r = subprocess.run(["/bin/bash", "-c", script, "-", str(ROOT / "deploy_guide.sh"), kind],
                                   capture_output=True, text=True, env=dict(self.env, **env), timeout=60)
                self.assertEqual(r.stdout.strip(), expected, r.stderr)


if __name__ == "__main__":
    unittest.main()

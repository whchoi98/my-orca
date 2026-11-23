"""Tests for deploy_orca_tf.sh. Run: python3 -I test/deploy_script_test.py

The script runs from a temp dir with fake aws, terraform and curl on PATH and a fake
set_password.sh next to it. Nothing here reaches AWS. The real apply is exercised on a real
account only.
"""
import json
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "deploy_orca_tf.sh"

LISTENER = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:listener/app/host/0123456789abcdef/0123456789abcdef"
LOAD_BALANCER = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/host/0123456789abcdef"
INSTANCE = "i-0123456789abcdef0"

FAKE_AWS = r"""#!/bin/bash
echo "$*" >> "$FAKE_DIR/aws-calls"
all="$*"
case "$1 $2" in
    "sts get-caller-identity")
        [[ "$all" == *"--query Account"* ]] && echo 123456789012 || echo "arn:aws:iam::123456789012:user/tester" ;;
    "cloudformation describe-stacks") [ -z "${FAKE_NO_HOST_STACK:-}" ] || exit 255 ;;
    "cloudformation list-stack-resources")
        if [[ "$all" == *"AWS::EC2::Instance"* ]]; then echo "${FAKE_INSTANCES-__INSTANCE__}"
        elif [[ "$all" == *"Listener"* ]]; then echo "__LISTENER__"
        fi ;;
    "ec2 describe-instances") echo "${FAKE_ARCH:-arm64}" ;;
    "elbv2 describe-listeners") printf '%s\t%s\t%s\n' "__LOAD_BALANCER__" "${FAKE_PORT:-80}" "${FAKE_PROTOCOL:-HTTP}" ;;
    "elbv2 describe-load-balancers")
        # Only a query that joins the list gets every security group of the ALB.
        if [[ "$all" == *'join('*'SecurityGroups)'* ]]; then
            printf '%s\t%s\n' "host-alb.example.test" "sg-0123456789abcdef1,sg-0123456789abcdef2"
        else
            printf '%s\t%s\n' "host-alb.example.test" "sg-0123456789abcdef1"
        fi ;;
    "ec2 describe-security-group-rules") echo "${FAKE_OPEN_RULES:-}" ;;
    "ssm describe-instance-information") echo "${FAKE_PING:-Online}" ;;
    "elbv2 describe-rules")
        if [[ "$all" == *"TargetGroupArn"* ]]; then echo "${FAKE_RULE_TARGETS:-}"
        else
            # "Rules[?Priority=='<gate>' || Priority=='<orca>'].Priority": answer the ones in use
            used=""
            for p in ${FAKE_USED_PRIORITIES:-}; do
                [[ "$all" == *"Priority=='$p'"* ]] && used="$used $p"
            done
            echo "${used# }"
        fi ;;
    "elbv2 describe-target-groups") echo "${FAKE_ORCA_TARGETS:-}" ;;
    "cloudfront-keyvaluestore get-key") [ -n "${FAKE_GATE_SET:-}" ] || exit 254 ;;
    "ec2 describe-vpcs") cat "$FAKE_DIR/vpcs.json" ;;
    "ec2 describe-subnets"|"ec2 describe-route-tables")
        vpc=$(grep -oE 'Values=vpc-[0-9a-f]+' <<<"$all" | head -n 1)
        cat "$FAKE_DIR/${2#describe-}-${vpc#Values=}.json" ;;
    "ec2 describe-vpc-endpoints") echo "${FAKE_ENDPOINTS:-}" ;;
    "ec2 describe-instance-type-offerings")
        # Answer the requested types that the region offers (all of them unless FAKE_NOT_OFFERED names some).
        wanted=$(grep -oE 'Name=instance-type,Values=[^ ]+' <<<"$all" | sed 's/.*Values=//' | tr ',' ' ')
        for type in $wanted; do
            [[ " ${FAKE_NOT_OFFERED:-} " == *" $type "* ]] || echo "$type"
        done ;;
    "ec2 describe-instance-types") echo "${FAKE_CUSTOM_ARCH:-x86_64}" ;;
    *) echo "unexpected aws call: $all" >&2; exit 99 ;;
esac
""".replace("__INSTANCE__", INSTANCE).replace("__LISTENER__", LISTENER).replace("__LOAD_BALANCER__", LOAD_BALANCER)

FAKE_TERRAFORM = r"""#!/bin/bash
echo "$*" >> "$FAKE_DIR/terraform-calls"
args=("$@")
[[ "${args[0]}" == -chdir=* ]] && args=("${args[@]:1}")
case "${args[0]}" in
    init) exit "${FAKE_INIT_RC:-0}" ;;
    state) for line in ${FAKE_STATE:-}; do echo "$line"; done ;;
    output)
        name="${args[${#args[@]}-1]}"
        var="FAKE_OUT_$name"
        [ -n "${!var:-}" ] || exit 1
        printf '%s' "${!var}" ;;
    plan)
        for arg in "${args[@]}"; do
            case "$arg" in
                -var-file=*) cp "${arg#-var-file=}" "$FAKE_DIR/planned-vars.json" ;;
                -out=*) echo plan > "${arg#-out=}" ;;
            esac
        done
        echo "Plan: 3 to add, 0 to change, 0 to destroy."
        exit "${FAKE_PLAN_RC:-0}" ;;
    apply) echo "Apply complete!"; exit "${FAKE_APPLY_RC:-0}" ;;
esac
"""

FAKE_CURL = r"""#!/bin/bash
url="${@: -1}"
echo "$url" >> "$FAKE_DIR/curl-calls"
case "$url" in
    */releases/latest) [ -n "${FAKE_LATEST:-}" ] || exit 22; echo "{\"tag_name\": \"v$FAKE_LATEST\"}" ;;
    */releases/tags/v*)
        tag="${url##*/releases/tags/v}"
        [[ " ${FAKE_TAGS:-} " == *" $tag "* ]] || exit 22
        echo "{\"assets\": [{\"name\": \"orca-ide-$tag.aarch64.rpm\"}, {\"name\": \"orca-ide-$tag.x86_64.rpm\"}]}" ;;
    *) exit 22 ;;
esac
"""

FAKE_SET_PASSWORD = r"""#!/bin/bash
printf '%s\n' "$*" > "$(dirname "$0")/set-password-args"
cat > "$(dirname "$0")/set-password-stdin"
"""


VPC = "vpc-0123456789abcdef0"
SMALL_VPC = "vpc-0123456789abcdef1"
ONE_ZONE_VPC = "vpc-0123456789abcdef3"
NO_PRIVATE_VPC = "vpc-0123456789abcdef4"


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


def write_exec(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class DeployScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        shutil.copy(SCRIPT, self.tmp / "deploy_orca_tf.sh")
        shutil.copy(SCRIPT.parent / "deploy_guide.sh", self.tmp / "deploy_guide.sh")
        write_vpc_fixture(self.tmp)
        write_exec(self.tmp / "set_password.sh", FAKE_SET_PASSWORD)
        for mode in ("dedicated", "attach"):
            (self.tmp / "infra-tf" / mode).mkdir(parents=True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        write_exec(bin_dir / "aws", FAKE_AWS)
        write_exec(bin_dir / "terraform", FAKE_TERRAFORM)
        write_exec(bin_dir / "curl", FAKE_CURL)
        self.env = {
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "HOME": str(self.tmp),
            "FAKE_DIR": str(self.tmp),
            "FAKE_LATEST": "1.4.270",
            "FAKE_TAGS": "1.4.260 1.4.269 1.4.270",
        }

    def run_script(self, *args, stdin="", **env):
        e = dict(self.env)
        e.update(env)
        return subprocess.run(["/bin/bash", str(self.tmp / "deploy_orca_tf.sh"), *args],
                              input=stdin, capture_output=True, text=True, env=e, timeout=60)

    def lines(self, name):
        path = self.tmp / name
        return path.read_text().splitlines() if path.exists() else []

    def terraform(self, verb):
        return [c for c in self.lines("terraform-calls") if f" {verb}" in f" {c.split(' ', 1)[-1]}" and c.split()[1] == verb]

    def planned(self):
        return json.loads((self.tmp / "planned-vars.json").read_text())

    def saved_path(self, mode):
        return self.tmp / "infra-tf" / mode / "orca.auto.tfvars.json"

    def save(self, mode, **values):
        self.saved_path(mode).write_text(json.dumps(values))

    def leftovers(self, mode):
        return sorted(p.name for p in (self.tmp / "infra-tf" / mode).iterdir() if p.name != "orca.auto.tfvars.json")

    # ---------------- dedicated ----------------
    def test_first_dedicated_deploy_uses_the_latest_release_and_saves_its_inputs(self):
        r = self.run_script("--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.planned(), {"orca_version": "1.4.270", "region": "ap-northeast-2"})
        self.assertEqual(len(self.terraform("apply")), 1)
        self.assertIn("infra-tf/dedicated", self.terraform("apply")[0])
        saved = self.saved_path("dedicated")
        self.assertEqual(json.loads(saved.read_text()), self.planned())
        # The inputs name the host; the state beside them holds the header secret.
        self.assertEqual(stat.S_IMODE(saved.stat().st_mode), 0o600)
        self.assertEqual(self.leftovers("dedicated"), [])
        self.assertIn("get_pairing_url.sh --tf dedicated", r.stdout)

    def test_plan_only_creates_and_keeps_nothing(self):
        r = self.run_script("--plan", "--instance-type", "m7g.xlarge")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.terraform("plan")), 1)
        self.assertEqual(self.terraform("apply"), [])
        self.assertFalse(self.saved_path("dedicated").exists())
        self.assertEqual(self.leftovers("dedicated"), [])
        self.assertEqual(self.planned()["instance_type"], "m7g.xlarge")

    def test_options_not_given_keep_their_saved_values(self):
        self.save("dedicated", region="us-west-2", orca_version="1.4.260", password_gate=False, instance_type="m7g.xlarge")
        r = self.run_script("--yes", FAKE_STATE="aws_instance.orca")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.planned(), {
            "region": "us-west-2", "orca_version": "1.4.260", "password_gate": False, "instance_type": "m7g.xlarge",
        })
        # The saved version is kept: no look-up of the latest release, no asset check.
        self.assertEqual(self.lines("curl-calls"), [])
        self.assertIn("사용 안 함", r.stdout)

    def test_given_options_override_the_saved_values(self):
        self.save("dedicated", region="us-west-2", orca_version="1.4.260", password_gate=False)
        r = self.run_script("--yes", "--region", "ap-northeast-2", "--orca-version", "v1.4.269", "--password-gate",
                            "--name", "orca-two", "--skip-vpc-endpoints", "--vpc-name", "lab")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.planned(), {
            "region": "ap-northeast-2", "orca_version": "1.4.269", "password_gate": True, "name": "orca-two",
            "create_ssm_endpoints": False, "vpc_name": "lab",
        })
        self.assertIn("v1.4.260 에서 v1.4.269", r.stdout)

    def test_existing_vpc_options(self):
        r = self.run_script("--plan", "--vpc-id", "vpc-0123456789abcdef0", "--alb-subnets",
                            "subnet-0123456789abcdef1, subnet-0123456789abcdef2", "--instance-subnet", "subnet-0123456789abcdef3")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.planned()["alb_subnet_ids"], ["subnet-0123456789abcdef1", "subnet-0123456789abcdef2"])
        self.assertEqual(self.planned()["instance_subnet_id"], "subnet-0123456789abcdef3")
        self.assertEqual(self.planned()["vpc_id"], "vpc-0123456789abcdef0")

    def test_unknown_release_stops_before_terraform_plans(self):
        r = self.run_script("--yes", "--orca-version", "9.9.9")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("릴리스 자산을 찾지 못했습니다", r.stderr)
        self.assertEqual(self.terraform("plan"), [])
        self.assertFalse(self.saved_path("dedicated").exists())

    def test_x86_instance_type_checks_the_x86_package(self):
        r = self.run_script("--plan", "--instance-type", "m7i.xlarge")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("x86_64 RPM", r.stdout)

    def test_failed_plan_saves_nothing(self):
        r = self.run_script("--yes", FAKE_PLAN_RC="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.terraform("apply"), [])
        self.assertFalse(self.saved_path("dedicated").exists())
        self.assertEqual(self.leftovers("dedicated"), [])

    def test_failed_apply_keeps_the_inputs_that_match_the_state(self):
        r = self.run_script("--yes", FAKE_APPLY_RC="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(self.saved_path("dedicated").exists())
        self.assertEqual(self.leftovers("dedicated"), [])

    def test_password_goes_to_set_password_on_stdin_only(self):
        r = self.run_script("--yes", ORCA_WEB_PASSWORD="correct horse 배터리")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.lines("set-password-args"), ["--tf dedicated --password-stdin"])
        self.assertEqual(self.lines("set-password-stdin"), ["correct horse 배터리"])
        self.assertNotIn("correct horse", r.stdout + r.stderr)
        self.assertNotIn("correct horse", "\n".join(self.lines("terraform-calls") + self.lines("aws-calls")))
        self.assertNotIn("correct horse", self.saved_path("dedicated").read_text())

    def test_password_is_not_set_without_the_gate_or_on_plan(self):
        self.run_script("--yes", "--no-password-gate", ORCA_WEB_PASSWORD="correct horse")
        self.assertEqual(self.lines("set-password-args"), [])
        self.run_script("--plan", ORCA_WEB_PASSWORD="correct horse")
        self.assertEqual(self.lines("set-password-args"), [])

    def test_interactive_password_keeps_its_spaces(self):
        answers = "\n\n\n\n" + "  spaced pass  \n" + "  spaced pass  \n" + "y\n"
        r = self.run_script(stdin=answers)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.tmp / "set-password-stdin").read_text(), "  spaced pass  \n")

    def test_interactive_decline_applies_nothing(self):
        r = self.run_script(stdin="\n\n\n\n\nn\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.terraform("apply"), [])
        self.assertFalse(self.saved_path("dedicated").exists())
        self.assertEqual(self.leftovers("dedicated"), [])

    # ---------------- the guide (deploy_guide.sh) ----------------
    def test_guide_new_vpc_with_a_name_and_a_type_from_the_menu(self):
        # region: 2nd in the list, VPC: new, its name, instance type: 9th, no password, yes
        r = self.run_script(stdin="2\n1\nlab-net\n9\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.planned(), {
            "region": "ap-northeast-1", "orca_version": "1.4.270", "vpc_name": "lab-net", "instance_type": "t4g.xlarge",
        })
        self.assertEqual(len(self.terraform("apply")), 1)

    def test_guide_existing_vpc_from_the_list(self):
        # region default, VPC: existing, 1st VPC, EC2 subnet: 2nd private one, type default, no password, yes
        r = self.run_script(stdin="\n2\n1\n2\n\n\ny\n", FAKE_ENDPOINTS="vpce-0123456789abcdef0\tvpce-0123456789abcdef1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.planned(), {
            "region": "ap-northeast-2", "orca_version": "1.4.270", "vpc_id": VPC,
            # One public subnet per Availability Zone for the ALB.
            "alb_subnet_ids": ["subnet-0123456789abcdef1", "subnet-0123456789abcdef2"],
            "instance_subnet_id": "subnet-0123456789abcdef4",
            # The VPC already has SSM endpoints: a second set would clash on private DNS.
            "create_ssm_endpoints": False,
            "instance_type": "r6g.xlarge",
        })
        # The subnets are shown with the kind CDK would give them.
        shown = [" ".join(line.split()) for line in r.stdout.splitlines()]
        for line in ("subnet-0123456789abcdef1 ap-northeast-2a 퍼블릭 pub-a", "subnet-0123456789abcdef2 ap-northeast-2b 퍼블릭 pub-b",
                     "subnet-0123456789abcdef7 ap-northeast-2a 퍼블릭 pub-a2",
                     "subnet-0123456789abcdef3 ap-northeast-2a 프라이빗 priv-a", "subnet-0123456789abcdef4 ap-northeast-2b 프라이빗 priv-b",
                     "subnet-0123456789abcdef5 ap-northeast-2a 격리 iso-a", "subnet-0123456789abcdef6 ap-northeast-2a 격리 tagged"):
            self.assertIn(line, shown)

    def test_guide_goes_back_when_the_vpc_cannot_be_used(self):
        # VPC: existing, 2nd VPC (one public subnet only), then new VPC with the default name
        r = self.run_script(stdin="\n2\n2\n1\n\n\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("이 VPC는 쓸 수 없습니다", r.stdout)
        self.assertNotIn("vpc_id", self.planned())
        self.assertEqual(self.planned()["vpc_name"], "orca-vpc")

    def test_guide_takes_a_vpc_id_and_refuses_one_that_is_not_listed(self):
        r = self.run_script(stdin=f"\n2\nvpc-0123456789abcdef9\n2\n{VPC}\n\n\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("목록에 없는 값입니다", r.stdout)
        self.assertEqual(self.planned()["vpc_id"], VPC)
        self.assertEqual(self.planned()["instance_subnet_id"], "subnet-0123456789abcdef3")
        self.assertNotIn("create_ssm_endpoints", self.planned())

    def test_vpc_id_alone_finds_its_subnets(self):
        # --yes asks nothing: an answer waiting on stdin must not pick the second subnet.
        r = self.run_script("--vpc-id", VPC, "--yes", stdin="2\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("EC2를 둘 프라이빗 서브넷을 고릅니다", r.stdout)
        self.assertEqual(self.planned()["alb_subnet_ids"], ["subnet-0123456789abcdef1", "subnet-0123456789abcdef2"])
        self.assertEqual(self.planned()["instance_subnet_id"], "subnet-0123456789abcdef3")

    def test_vpc_id_that_cannot_be_used_stops_before_the_plan(self):
        for vpc in (SMALL_VPC, ONE_ZONE_VPC, NO_PRIVATE_VPC):
            with self.subTest(vpc):
                r = self.run_script("--vpc-id", vpc, "--yes")
                self.assertNotEqual(r.returncode, 0)
                self.assertIn("쓸 수 없습니다", r.stdout + r.stderr)
                self.assertEqual(self.terraform("plan"), [])

    def test_plan_asks_nothing(self):
        # Answers waiting on stdin (region 2, existing VPC...) must not be read.
        r = self.run_script("--plan", stdin="2\n2\n1\n2\n9\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for title in ("[리전]", "[VPC]", "[인스턴스 타입]"):
            self.assertNotIn(title, r.stdout)
        self.assertEqual(self.planned(), {"orca_version": "1.4.270", "region": "ap-northeast-2"})

    def test_given_subnets_are_not_looked_up_again(self):
        r = self.run_script("--vpc-id", SMALL_VPC, "--alb-subnets", "subnet-0123456789abcdef1,subnet-0123456789abcdef2",
                            "--instance-subnet", "subnet-0123456789abcdef3", "--plan")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(any("describe-subnets" in c for c in self.lines("aws-calls")))

    def test_endpoints_are_kept_when_asked_for_or_already_decided(self):
        r = self.run_script("--vpc-id", VPC, "--skip-vpc-endpoints", "--plan", FAKE_ENDPOINTS="vpce-0123456789abcdef0")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(any("describe-vpc-endpoints" in c for c in self.lines("aws-calls")))
        self.assertEqual(self.planned()["create_ssm_endpoints"], False)

    def test_a_deployed_server_keeps_its_vpc_without_questions(self):
        self.save("dedicated", region="ap-northeast-2", orca_version="1.4.260", vpc_id=VPC, instance_type="m7g.xlarge",
                  alb_subnet_ids=["subnet-0123456789abcdef1", "subnet-0123456789abcdef2"], instance_subnet_id="subnet-0123456789abcdef3")
        # Only the password prompt and the confirmation are left.
        r = self.run_script(stdin="\ny\n", FAKE_STATE="aws_instance.orca", FAKE_ENDPOINTS="vpce-0123456789abcdef0")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.planned()["vpc_id"], VPC)
        self.assertEqual(self.planned()["instance_type"], "m7g.xlarge")
        # Its own endpoints are in that VPC by now; they must not be taken for someone else's.
        self.assertNotIn("create_ssm_endpoints", self.planned())
        self.assertFalse(any("describe-vpcs" in c or "describe-vpc-endpoints" in c for c in self.lines("aws-calls")))

    def test_guide_instance_type_outside_the_list(self):
        # type: 0 (custom), then a type the region does not have, then one it has
        r = self.run_script("--region", "ap-northeast-2", stdin="1\n\n0\nz9.huge\n0\nc7g.xlarge\n\ny\n",
                            FAKE_NOT_OFFERED="z9.huge", FAKE_CUSTOM_ARCH="arm64")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("z9.huge 은 ap-northeast-2 리전에 없는 타입입니다", r.stdout)
        self.assertEqual(self.planned()["instance_type"], "c7g.xlarge")
        self.assertIn("aarch64 RPM", r.stdout)

    def test_guide_refuses_a_listed_type_the_region_does_not_offer(self):
        r = self.run_script("--region", "ap-northeast-2", stdin="1\n\n1\n3\n\ny\n", FAKE_NOT_OFFERED="r6g.xlarge")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("r6g.xlarge    ARM64 Graviton, 4 vCPU, 32GB  (이 리전에서 제공하지 않음)", r.stdout)
        self.assertIn("r6g.xlarge 은 ap-northeast-2 리전에서 제공하지 않습니다", r.stdout)
        self.assertEqual(self.planned()["instance_type"], "r7g.xlarge")

    def test_guide_region_by_code_and_bad_input(self):
        r = self.run_script(stdin="99\nseoul\neu-north-1\n\n\n\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.count("목록의 번호나 리전 코드"), 2)
        self.assertEqual(self.planned()["region"], "eu-north-1")

    def test_options_skip_their_questions(self):
        # Region, VPC and type are given: what is left is the EC2 subnet, the password and the confirmation.
        r = self.run_script("--region", "us-west-2", "--vpc-id", VPC, "--instance-type", "m7g.xlarge", stdin="2\n\ny\n")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for title in ("[리전]", "[VPC]", "[인스턴스 타입]"):
            self.assertNotIn(title, r.stdout)
        self.assertEqual(self.planned()["region"], "us-west-2")
        self.assertEqual(self.planned()["instance_type"], "m7g.xlarge")
        self.assertEqual(self.planned()["instance_subnet_id"], "subnet-0123456789abcdef4")

    def test_bad_arguments(self):
        for args in (["--attach", "Host", "--instance-type", "r6g.xlarge"], ["--attach-instance", INSTANCE],
                     ["--attach", "Host", "--attach-instance", INSTANCE, "--attach-listener", LISTENER],
                     ["--name"], ["--name", "--yes"], ["--no-such-option"]):
            with self.subTest(args):
                r = self.run_script("--plan", *args)
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(self.lines("terraform-calls"), [])

    # ---------------- attach ----------------
    def test_attach_finds_the_host_in_its_stack(self):
        r = self.run_script("--attach", "VscodeServerStack", "--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.planned(), {
            "region": "ap-northeast-2", "orca_version": "1.4.270", "host_instance_id": INSTANCE,
            "host_listener_arn": LISTENER, "host_label": "VscodeServerStack",
        })
        self.assertIn("infra-tf/attach", self.terraform("apply")[0])
        self.assertTrue(self.saved_path("attach").exists())
        self.assertFalse(self.saved_path("dedicated").exists())

    def test_attach_to_a_server_named_directly(self):
        r = self.run_script("--attach-instance", INSTANCE, "--attach-listener", LISTENER, "--host-instance-sg",
                            "sg-0123456789abcdef0", "--host-alb-sg", "sg-0123456789abcdef1", "--plan")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        planned = self.planned()
        self.assertEqual(planned["host_instance_id"], INSTANCE)
        self.assertEqual(planned["host_label"], INSTANCE)
        self.assertEqual(planned["host_instance_security_group_id"], "sg-0123456789abcdef0")
        self.assertEqual(planned["host_alb_security_group_id"], "sg-0123456789abcdef1")
        self.assertFalse(any("cloudformation" in c for c in self.lines("aws-calls")))

    def test_attach_checks_every_security_group_of_the_alb(self):
        self.run_script("--attach", "Host", "--plan")
        call = next(c for c in self.lines("aws-calls") if "describe-security-group-rules" in c)
        self.assertIn("Values=sg-0123456789abcdef1,sg-0123456789abcdef2", call)

    def test_attach_refuses_a_host_that_already_has_orca(self):
        r = self.run_script("--attach", "Host", "--yes", FAKE_RULE_TARGETS="arn:tg/one arn:tg/two", FAKE_ORCA_TARGETS="OrcaOnVscodeStack-TG")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("이미 Orca", r.stderr)
        self.assertEqual(self.terraform("plan"), [])

    def test_attach_updates_its_own_deployment(self):
        # The same rules are there on a later run, but now they are this deployment's own.
        r = self.run_script("--attach", "Host", "--yes", FAKE_STATE="module.routes.aws_lb_listener_rule.orca",
                            FAKE_RULE_TARGETS="arn:tg/one", FAKE_ORCA_TARGETS="orca-on-vscode-tg", FAKE_USED_PRIORITIES="5 10")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.terraform("apply")), 1)

    def test_attach_refuses_priorities_in_use(self):
        r = self.run_script("--attach", "Host", "--yes", FAKE_USED_PRIORITIES="10")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("우선순위 10", r.stderr)
        self.assertEqual(self.terraform("plan"), [])

    def test_attach_with_other_priorities(self):
        r = self.run_script("--attach", "Host", "--yes", "--orca-rule-priority", "40", "--gate-rule-priority", "35",
                            FAKE_USED_PRIORITIES="5 10")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.planned()["orca_rule_priority"], 40)
        self.assertEqual(self.planned()["gate_setup_rule_priority"], 35)

    def test_attach_precondition_failures(self):
        cases = {
            "missing host stack": ({"FAKE_NO_HOST_STACK": "1"}, "찾지 못했습니다"),
            "two instances in the stack": ({"FAKE_INSTANCES": f"{INSTANCE} i-0123456789abcdef1"}, "여러 개"),
            "listener is HTTPS": ({"FAKE_PORT": "443", "FAKE_PROTOCOL": "HTTPS"}, "HTTP:80"),
            "listener is HTTP on another port": ({"FAKE_PORT": "8080"}, "HTTP:80"),
            "listener is HTTPS on port 80": ({"FAKE_PROTOCOL": "HTTPS"}, "HTTP:80"),
            "ALB open to the world": ({"FAKE_OPEN_RULES": "sgr-0123456789abcdef0"}, "인터넷 전체에 열려"),
            "SSM agent offline": ({"FAKE_PING": "ConnectionLost"}, "온라인이 아닙니다"),
        }
        for name, (env, message) in cases.items():
            with self.subTest(name):
                (self.tmp / "terraform-calls").unlink(missing_ok=True)
                r = self.run_script("--attach", "Host", "--yes", **env)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(message, r.stderr)
                self.assertEqual(self.terraform("plan"), [])
                self.assertFalse(self.saved_path("attach").exists())

    def test_attach_checks_the_package_of_the_host_architecture(self):
        r = self.run_script("--attach", "Host", "--plan", FAKE_ARCH="x86_64")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("x86_64 RPM", r.stdout)

    def test_upgrade_keeps_the_other_saved_inputs(self):
        self.save("attach", region="ap-northeast-2", orca_version="1.4.260", password_gate=False, name="orca-lab",
                  host_instance_id=INSTANCE, host_listener_arn=LISTENER, host_label="Host")
        r = self.run_script("--attach", "Host", "--orca-version", "1.4.269", "--yes", FAKE_STATE="terraform_data.host_install")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        planned = self.planned()
        self.assertEqual(planned["orca_version"], "1.4.269")
        self.assertEqual(planned["password_gate"], False)
        self.assertEqual(planned["name"], "orca-lab")

    def test_no_secret_or_link_in_the_output(self):
        r = self.run_script("--attach", "Host", "--yes", FAKE_OUT_cloudfront_url="https://example.test",
                            FAKE_OUT_instance_id=INSTANCE, FAKE_OUT_orca_version="1.4.270")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("https://example.test", r.stdout)
        for needle in ("orca://pair", "pairing=", "gate-setup="):
            self.assertNotIn(needle, r.stdout + r.stderr)
        # The script itself never asks Terraform for the state or a sensitive value.
        for call in self.lines("terraform-calls"):
            self.assertNotRegex(call, r"\b(show|state pull|state show)\b")
            self.assertNotIn("-json", call)

    def test_help_lists_every_option_the_parser_takes(self):
        r = self.run_script("--help")
        self.assertEqual(r.returncode, 0)
        script = SCRIPT.read_text()
        parser = script[script.index('while [ "$#" -gt 0 ]; do'):script.index("die() {")]
        options = sorted(set(line.strip().split(")")[0].split("|")[0] for line in parser.splitlines()
                             if line.strip().startswith("--") and ")" in line) - {"--help"})
        self.assertGreaterEqual(len(options), 20)
        # Each option needs its own line in the option list; the examples above it do not count.
        listed = r.stdout[r.stdout.index("옵션:"):]
        for option in options:
            with self.subTest(option):
                self.assertRegex(listed, rf"(?m)^  {re.escape(option)}( |$)")
        self.assertEqual(self.lines("terraform-calls") + self.lines("aws-calls"), [])


if __name__ == "__main__":
    unittest.main()

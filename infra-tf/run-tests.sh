#!/bin/bash
# Tests for the Terraform deployment. No AWS calls and no credentials: the AWS provider is
# mocked. The first run downloads the providers (terraform init, a few hundred MB).
#
#   bash infra-tf/run-tests.sh
#
#   1. terraform fmt -check             formatting
#   2. terraform validate               both root modules
#   3. terraform test                   dedicated/tests/dedicated.tftest.hcl, variants.tftest.hcl,
#                                       modules.tftest.hcl and attach/tests/attach.tftest.hcl
#   4. the setup bundle                 holds the two files of infra-cdk/lib/gate, with fixed modes, and nothing else
#   5. python3 -I test/ssm_run_test.py        scripts/ssm_run.sh with a fake aws
#   6. python3 -I test/deploy_script_test.py  ../deploy_orca_tf.sh with fake aws, terraform and curl
#   7. python3 -I test/ops_scripts_test.py    the --tf option of get_pairing_url.sh, set_password.sh, cleanup.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
command -v terraform >/dev/null 2>&1 || { echo "terraform is required (https://developer.hashicorp.com/terraform/install)" >&2; exit 1; }

step() { echo; echo "== $*"; }

step "terraform fmt -check"
terraform fmt -check -recursive -diff .

for root in dedicated attach; do
    step "$root: terraform init, validate, test"
    # -backend=false: no state is read or written here.
    if ! INIT_OUTPUT=$(terraform -chdir="$root" init -backend=false -input=false -no-color 2>&1); then
        echo "$INIT_OUTPUT" >&2
        exit 1
    fi
    terraform -chdir="$root" validate -no-color
    terraform -chdir="$root" test -no-color
done

step "setup bundle contents"
# The test runs above built the bundle (archive_file). A stray file, e.g. __pycache__, would
# change its hash and re-run the install on every attached host.
BUNDLE=modules/front-door/.build/gate.zip
[ -f "$BUNDLE" ] || { echo "$BUNDLE was not built" >&2; exit 1; }
# Name and mode of every entry. The modes are fixed (output_file_mode) so that the hash does not
# depend on the umask of the machine that built the bundle.
NAMES=$(python3 -I -c 'import sys, zipfile
print(" ".join(sorted(f"{i.filename}:{(i.external_attr >> 16) & 0o777:o}" for i in zipfile.ZipFile(sys.argv[1]).infolist())))' "$BUNDLE")
if [ "$NAMES" != "install.sh:644 setup_service.py:644" ]; then
    echo "unexpected files or modes in $BUNDLE: $NAMES" >&2
    exit 1
fi
echo "ok: $NAMES"

for test in ssm_run_test.py deploy_script_test.py ops_scripts_test.py; do
    step "python3 -I test/$test"
    python3 -I "test/$test"
done

echo
echo "All infra-tf tests passed."

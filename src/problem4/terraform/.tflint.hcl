config {
  # Modules are linted through the roots that call them; linting them standalone
  # produces false positives for variables that are always supplied.
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # deep_check would call the AWS API to validate instance types, AMI IDs and the
  # like. The plan job already talks to AWS with a read-only role; keeping the
  # lint job credential-free means it can run on fork pull requests.
  deep_check = false
}

# Naming convention, enforced rather than documented.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Every variable and output must carry a description. This is the rule that keeps
# a module usable by someone who did not write it.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Typed variables only — an untyped variable accepts a string where a list was
# meant and fails at apply time, which for infrastructure means halfway through.
rule "terraform_typed_variables" {
  enabled = true
}

# Provider versions must be constrained. An unpinned provider means CI can
# produce a different plan tomorrow from the same commit.
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

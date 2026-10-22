# Runs offline: `terraform test` / `tofu test` from providers/aws/modules/network.

mock_provider "aws" {
  # t3.micro exists in AZs a and b, t4g.small in b and e.
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = {
      instance_types = ["t3.micro", "t3.micro", "t4g.small", "t4g.small"]
      locations      = ["us-east-1a", "us-east-1b", "us-east-1b", "us-east-1e"]
    }
  }
}

run "subnet_goes_to_an_az_offering_every_type" {
  command = plan

  variables {
    instance_types = ["t3.micro", "t4g.small"]
  }

  assert {
    condition     = output.availability_zone == "us-east-1b" && aws_subnet.public.availability_zone == "us-east-1b"
    error_message = "us-east-1b is the only AZ that offers both types."
  }

  assert {
    condition     = !aws_subnet.public.map_public_ip_on_launch
    error_message = "Public IPv4 is billed, so instances must opt in."
  }
}

run "pinned_az_wins" {
  command = plan

  variables {
    instance_types    = ["t3.micro"]
    availability_zone = "us-east-1c"
  }

  assert {
    condition     = output.availability_zone == "us-east-1c"
    error_message = "An explicit availability_zone overrides the lookup."
  }
}

run "ports_and_cidrs_become_rules" {
  command = plan

  variables {
    ssh_source_cidrs  = ["203.0.113.7/32", "2001:db8::/32"]
    ingress_tcp_ports = [80, 443, 8080]
    ingress_udp_ports = [51820]
  }

  assert {
    condition     = output.ingress.tcp_ports == toset([80, 443, 8080]) && output.ingress.udp_ports == toset([51820])
    error_message = "Every ingress port should get a rule."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.ssh["203.0.113.7/32"].cidr_ipv4 == "203.0.113.7/32" &&
      aws_vpc_security_group_ingress_rule.ssh["2001:db8::/32"].cidr_ipv6 == "2001:db8::/32"
    )
    error_message = "IPv4 and IPv6 SSH sources should land in the matching rule field."
  }
}

run "empty_lists_create_no_rules" {
  command = plan

  variables {
    ssh_source_cidrs  = []
    ingress_tcp_ports = []
    ingress_udp_ports = []
  }

  assert {
    condition     = length(output.ingress.ssh_source_cidrs) == 0 && length(output.ingress.tcp_ports) == 0 && length(output.ingress.udp_ports) == 0
    error_message = "Empty lists should create no ingress rules."
  }
}

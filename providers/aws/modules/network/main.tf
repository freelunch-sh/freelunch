locals {
  tags = { "managed-by" = "freelunch" }

  # Not every instance type exists in every AZ (us-east-1e has no t3 or t4g, for example).
  # Pick the first AZ that offers all of them, unless one is pinned.
  offerings = one(data.aws_ec2_instance_type_offerings.this[*])
  azs_by_type = {
    for t in var.instance_types : t => [
      for i, az in try(local.offerings.locations, []) : az if local.offerings.instance_types[i] == t
    ]
  }
  common_azs        = length(var.instance_types) > 0 ? sort(setintersection(values(local.azs_by_type)...)) : []
  availability_zone = var.availability_zone != null ? var.availability_zone : try(local.common_azs[0], null)
}

data "aws_ec2_instance_type_offerings" "this" {
  count = length(var.instance_types) > 0 ? 1 : 0

  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = var.instance_types
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.subnet_cidr
  availability_zone = local.availability_zone
  tags              = merge(local.tags, { Name = "${var.name}-public" })

  # Public IPv4 addresses are billed per hour; instances opt in one by one.
  map_public_ip_on_launch = false
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-public-rt" })

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "this" {
  name        = "${var.name}-hosts"
  description = "freelunch Docker hosts"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name}-hosts" })
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "All egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_source_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "SSH"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = strcontains(each.value, ":") ? null : each.value
  cidr_ipv6         = strcontains(each.value, ":") ? each.value : null
}

resource "aws_vpc_security_group_ingress_rule" "tcp" {
  for_each = toset([for p in var.ingress_tcp_ports : tostring(p)])

  security_group_id = aws_security_group.this.id
  description       = "tcp/${each.value}"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "udp" {
  for_each = toset([for p in var.ingress_udp_ports : tostring(p)])

  security_group_id = aws_security_group.this.id
  description       = "udp/${each.value}"
  ip_protocol       = "udp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = "0.0.0.0/0"
}

# Path MTU discovery; without it large responses can stall. For ICMP, from_port is the
# type and to_port the code.
resource "aws_vpc_security_group_ingress_rule" "icmp_fragmentation_needed" {
  security_group_id = aws_security_group.this.id
  description       = "ICMP fragmentation needed"
  ip_protocol       = "icmp"
  from_port         = 3
  to_port           = 4
  cidr_ipv4         = "0.0.0.0/0"
}

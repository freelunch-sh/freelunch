resource "google_compute_network" "this" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "public" {
  name          = "${var.name}-public"
  network       = google_compute_network.this.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr
}

# Rules carry no target tags, so they apply to every instance in this dedicated VPC.
# An `allow` block without `ports` opens every port, so each rule exists only when it has
# something to allow.

resource "google_compute_firewall" "ssh" {
  count = length(var.ssh_source_cidrs) > 0 ? 1 : 0

  name          = "${var.name}-allow-ssh"
  network       = google_compute_network.this.id
  direction     = "INGRESS"
  source_ranges = var.ssh_source_cidrs

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "tcp" {
  count = length(var.ingress_tcp_ports) > 0 ? 1 : 0

  name          = "${var.name}-allow-tcp"
  network       = google_compute_network.this.id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = [for p in var.ingress_tcp_ports : tostring(p)]
  }
}

resource "google_compute_firewall" "udp" {
  count = length(var.ingress_udp_ports) > 0 ? 1 : 0

  name          = "${var.name}-allow-udp"
  network       = google_compute_network.this.id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "udp"
    ports    = [for p in var.ingress_udp_ports : tostring(p)]
  }
}

# Ping and path MTU discovery. GCP firewall rules can't filter by ICMP type.
resource "google_compute_firewall" "icmp" {
  name          = "${var.name}-allow-icmp"
  network       = google_compute_network.this.id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "icmp"
  }
}

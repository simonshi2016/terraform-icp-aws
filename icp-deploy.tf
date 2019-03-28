resource "aws_s3_bucket_object" "icp_cert_crt" {
  count = "${var.user_provided_cert_dns != "" ? 1 : 0}"
  bucket = "${aws_s3_bucket.icp_config_backup.id}"
  key    = "cfc-certs/icp-auth.crt"
  source = "${path.module}/cfc-certs/icp-auth.crt"
}

resource "aws_s3_bucket_object" "icp_cert_key" {
  count = "${var.user_provided_cert_dns != "" ? 1 : 0}"
  bucket = "${aws_s3_bucket.icp_config_backup.id}"
  key    = "cfc-certs/icp-auth.key"
  source = "${path.module}/cfc-certs/icp-auth.key"
}

resource "aws_s3_bucket_object" "hostfile" {
  bucket = "${aws_s3_bucket.icp_config_backup.id}"
  key    = "hosts"
  content = <<EOF
[master]
${join("\n", formatlist("%v", aws_network_interface.mastervip.*.private_ip))}

[proxy]
${var.proxy["nodes"] > 0 ?
  join("\n", formatlist("%v", aws_network_interface.proxyvip.*.private_ip)) :
  join("\n", formatlist("%v", aws_network_interface.mastervip.*.private_ip))
}

[management]
${var.management["nodes"] > 0 ?
  join("\n", formatlist("%v", aws_instance.icpmanagement.*.private_ip)) :
  join("\n", formatlist("%v", aws_network_interface.mastervip.*.private_ip))
}

${var.va["nodes"] > 0 ? "
[va]
${join("\n", formatlist("%v", aws_instance.icpva.*.private_ip))}
" :
""
}

[worker]
${join("\n", formatlist("%v", aws_instance.icpnodes.*.private_ip))}

EOF
#  source = "${path.module}/hostlist.txt"
}

resource "aws_s3_bucket_object" "icp_config_yaml" {
  bucket = "${aws_s3_bucket.icp_config_backup.id}"
  key    = "icp-terraform-config.yaml"
  content = <<EOF
kubelet_nodename: fqdn
${var.use_aws_cloudprovider ? "cloud_provider: aws" : "" }
calico_tunnel_mtu: 8981
ansible_user: icpdeploy
ansible_become: true
network_cidr: ${var.icp_network_cidr}
service_cluster_ip_range: ${var.icp_service_network_cidr}
default_admin_password: ${var.icppassword}
proxy_lb_address: ${aws_lb.icp-proxy.dns_name}
cluster_lb_address: ${aws_lb.icp-console.dns_name}
cluster_CA_domain: ${var.user_provided_cert_dns != "" ? var.user_provided_cert_dns : aws_lb.icp-console.dns_name}
disabled_management_services: [ "istio", "custom-metrics-adapter", "${var.va["nodes"] == 0 ? "va" : "" }", "${var.va["nodes"] == 0 ? "vulnerability-advisor": ""}" ]
kibana_install: true
EOF
#  source = "${path.module}/items-config.yaml"
}

resource "tls_private_key" "installkey" {
  algorithm   = "RSA"
}

resource "aws_s3_bucket_object" "ssh_key" {
  bucket = "${aws_s3_bucket.icp_config_backup.id}"
  key    = "ssh_key"
  content = "${tls_private_key.installkey.private_key_pem}"
}

output "ICP Console ELB DNS (internal)" {
  value = "${aws_lb.icp-console.dns_name}"
}

output "ICP Proxy ELB DNS (internal)" {
  value = "${aws_lb.icp-proxy.dns_name}"
}

output "ICP Console URL" {
  value = "https://${var.user_provided_cert_dns != "" ? var.user_provided_cert_dns : aws_lb.icp-console.dns_name}:8443"
}

output "ICP Registry ELB URL" {
  value = "https://${aws_lb.icp-console.dns_name}:8500"
}

output "ICP Kubernetes API URL" {
  value = "https://${aws_lb.icp-console.dns_name}:8001"
}

output "ICP Admin Username" {
  value = "admin"
}

output "ICP Admin Password" {
  value = "${var.icppassword}"
}

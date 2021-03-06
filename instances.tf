# Generate a new key if this is required for deployment
resource "random_id" "clusterid" {
  byte_length = "2"
}

locals  {
  iam_ec2_instance_profile_id = "${var.existing_ec2_iam_instance_profile_name != "" ?
        var.existing_ec2_iam_instance_profile_name :
        element(concat(aws_iam_instance_profile.icp_ec2_instance_profile.*.id, list("")), 0)}"
  efs_audit_mountpoints = "${concat(aws_efs_mount_target.icp-audit.*.dns_name, list(""))}"
  efs_registry_mountpoints = "${concat(aws_efs_mount_target.icp-registry.*.dns_name, list(""))}"
  efs_icp4d_mountpoints = "${var.icp4d_storage_efs != "0" ? "${element(concat(aws_efs_mount_target.icp4d-data.*.dns_name,list("")),0)}:/." : ""}"
  image_package_uri = "${substr(var.image_location, 0, min(2, length(var.image_location))) == "s3" ?
    var.image_location :
      var.image_location  == "" ? "" : "s3://${element(concat(aws_s3_bucket.icp_binaries.*.id, list("")), 0)}/${basename(var.image_location)}"}"
  image_icp4d_uri = "${substr(var.image_location_icp4d, 0, min(2, length(var.image_location_icp4d))) == "s3" ?
    var.image_location_icp4d :
      var.image_location_icp4d  == "" ? "" : "s3://${element(concat(aws_s3_bucket.icp_binaries.*.id, list("")), 0)}/${basename(var.image_location_icp4d)}"}"
  docker_package_uri = "${substr(var.docker_package_location, 0, min(2, length(var.docker_package_location))) == "s3" ?
    var.docker_package_location :
      var.docker_package_location == "" ? "" : "s3://${element(concat(aws_s3_bucket.icp_binaries.*.id, list("")), 0)}/icp-docker.bin"}"
  lambda_s3_bucket = "${element(concat(aws_s3_bucket.icp_lambda.*.id, list("")), 0)}"
  default_ami = "${var.ami != "" ? var.ami : data.aws_ami.rhel.id}"
  icp_config_s3_bucket="${aws_s3_bucket.icp_config_backup.id}"
}

## Search for a default Ubuntu image to allow this option
data "aws_ami" "rhel" {
  most_recent = true

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "image-type"
    values = ["machine"]
  }

  filter {
    name   = "name"
    // values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
    values = ["RHEL*7.5_HVM*x86_64*Hourly*GP2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  // owners = ["099720109477"] # Canonical
  owners = ["309956199498"] # RedHat
}

## Search for a default Ubuntu image to allow this option
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "image-type"
    values = ["machine"]
  }

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
    //values = ["RHEL-7.4_HVM-*-x86_64-2-Hourly2-GP2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
  //owners = ["309956199498"] # RedHat
}

resource "aws_instance" "bastion" {
  count         = "${var.bastion["nodes"]}"
  key_name      = "${var.key_name}"
  ami           = "${var.bastion["ami"] != "" ? var.bastion["ami"] : local.default_ami }"
  instance_type = "${var.bastion["type"]}"
  subnet_id     = "${element(aws_subnet.icp_public_subnet.*.id, count.index)}"
  vpc_security_group_ids = [
    "${aws_security_group.default.id}",
    "${aws_security_group.bastion.id}"
  ]

  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"
  associate_public_ip_address = true

  root_block_device {
    volume_size = "${var.bastion["disk"]}"
  }

  tags = "${merge(var.default_tags, map(
    "Name",  "${format("${var.instance_name}-${random_id.clusterid.hex}-bastion%02d", count.index + 1) }"
  ))}"
  user_data = <<EOF
#cloud-config
fqdn: ${format("${var.instance_name}-bastion%02d", count.index + 1)}.${random_id.clusterid.hex}.${var.private_domain}
users:
- default
- name: icpdeploy
  groups: [ wheel ]
  sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
  shell: /bin/bash
  ssh-authorized-keys:
  - ${tls_private_key.installkey.public_key_openssh}
manage_resolv_conf: true
resolv_conf:
  nameservers: [ ${cidrhost(element(aws_subnet.icp_private_subnet.*.cidr_block, count.index), 2)}]
  domain: ${random_id.clusterid.hex}.${var.private_domain}
  searchdomains:
  - ${random_id.clusterid.hex}.${var.private_domain}
EOF
}

resource "aws_ebs_volume" "icpmaster_docker_ebs" {
  count = "${var.master["nodes"]}"
  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"
  size  = "${var.master["docker_vol"]}"
  type  = "gp2"
  tags = "${merge(
    var.default_tags,
    map("Name",  "${format("${var.instance_name}-${random_id.clusterid.hex}-master%02d-dockerdisk", count.index + 1) }")
  )}"
}

resource "aws_volume_attachment" "icpmaster_docker_ebs_att" {
  count = "${var.master["nodes"]}"
  device_name = "/dev/xvdx"
  volume_id   = "${element(aws_ebs_volume.icpmaster_docker_ebs.*.id,count.index)}"
  instance_id = "${element(aws_instance.icpmaster.*.id,count.index)}"
  skip_destroy = false
  force_detach = true
}

resource "aws_ebs_volume" "icpmaster_ibm_ebs" {
  count = "${var.master["nodes"]}"
  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"
  size  = "${var.master["ibm_vol"]}"
  type  = "gp2"
  tags = "${merge(
    var.default_tags,
    map("Name",  "${format("${var.instance_name}-${random_id.clusterid.hex}-master%02d-ibmdisk", count.index + 1) }")
  )}"
}

resource "aws_volume_attachment" "icpmaster_ibm_ebs_att" {
  count = "${var.master["nodes"]}"
  device_name = "/dev/xvdb"
  volume_id   = "${element(aws_ebs_volume.icpmaster_ibm_ebs.*.id,count.index)}"
  instance_id = "${element(aws_instance.icpmaster.*.id,count.index)}"
  skip_destroy = false
  force_detach = true
}

resource "aws_ebs_volume" "icpmaster_data_ebs" {
  count = "${var.icp4d_storage_efs == 0 && var.worker["nodes"] == 0 ? var.master["nodes"] : 0 }"
  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"
  size  = "${var.master["data_vol"]}"
  type  = "gp2"
  tags = "${merge(
    var.default_tags,
    map("Name",  "${format("${var.instance_name}-${random_id.clusterid.hex}-master%02d-datadisk", count.index + 1) }")
  )}"
}

resource "aws_volume_attachment" "icpmaster_data_ebs_att" {
  count = "${var.icp4d_storage_efs == 0 && var.worker["nodes"] ==0 ? var.master["nodes"] : 0 }"
  device_name = "/dev/xvdc"
  volume_id   = "${element(aws_ebs_volume.icpmaster_data_ebs.*.id,count.index)}"
  instance_id = "${element(aws_instance.icpmaster.*.id,count.index)}"
  skip_destroy = false
  force_detach = true
}

resource "aws_instance" "icpmaster" {
  depends_on = [
    "aws_route_table_association.a",
    "null_resource.icp_install_package",
    "aws_s3_bucket_object.docker_install_package",
    "aws_s3_bucket_object.hostfile",
    "aws_s3_bucket_object.icp_cert_crt",
    "aws_s3_bucket_object.icp_cert_key",
    "aws_s3_bucket_object.icp_config_yaml",
    "aws_s3_bucket_object.ssh_key",
    "aws_s3_bucket_object.bootstrap",
    "aws_s3_bucket_object.create_client_cert",
    "aws_s3_bucket_object.functions",
    "aws_s3_bucket_object.start_install"
  ]

  count         = "${var.master["nodes"]}"
  key_name      = "${var.key_name}"
  ami           = "${var.master["ami"] != "" ? var.master["ami"] : local.default_ami }"
  instance_type = "${var.master["type"]}"

  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"

  ebs_optimized = "${var.master["ebs_optimized"]}"
  root_block_device {
    volume_size = "${var.master["disk"]}"
  }

  network_interface {
    network_interface_id = "${element(aws_network_interface.mastervip.*.id, count.index)}"
    device_index = 0
  }

  iam_instance_profile = "${local.iam_ec2_instance_profile_id}"


  tags = "${merge(
    var.default_tags,
    map("Name", "${format("${var.instance_name}-${random_id.clusterid.hex}-master%02d", count.index + 1) }"),
    map("kubernetes.io/cluster/${random_id.clusterid.hex}", "${random_id.clusterid.hex}")
  )}"

  user_data = <<EOF
#cloud-config
packages:
- unzip
- python
rh_subscription:
  enable-repo: rhui-REGION-rhel-server-optional
write_files:
- path: /tmp/bootstrap-node.sh
  permissions: '0755'
  encoding: b64
  content: ${base64encode(file("${path.module}/scripts/bootstrap-node.sh"))}
${count.index == 0 ? "
- path: /root/.ssh/installkey
  permissions: '0600'
  encoding: b64
  content: ${base64encode("${tls_private_key.installkey.private_key_pem}")}"
  : ""
}
bootcmd:
- sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
- setenforce permissive
runcmd:
${count.index > 0 ? "
- /tmp/bootstrap-node.sh -c ${aws_s3_bucket.icp_config_backup.id} -s \"bootstrap.sh functions.sh ${count.index == 0 ? "start_install.sh" : ""} ${count.index == 0 && var.enable_autoscaling ? "create_client_cert.sh" : ""}\"
- /tmp/icp_scripts/bootstrap.sh ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdx ${local.image_package_uri != "" ? "-i ${local.image_package_uri}" : "" } -s ${var.icp_inception_image} ${length(var.patch_images) > 0 ? "-a \"${join(" ", var.patch_images)}\"" : "" }
" : "" }
${var.master["nodes"] > 1 ? "
mounts:
  - ['${element(local.efs_registry_mountpoints, count.index)}:/', '/var/lib/registry', 'nfs4', 'nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2', '0', '0']
  - ['${element(local.efs_audit_mountpoints, count.index)}:/', '/var/lib/icp/audit', 'nfs4', 'nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2', '0', '0']
"
:
"" }
disable_root: false
users:
- default
- name: icpdeploy
  groups: [ wheel ]
  sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
  shell: /bin/bash
  ssh-authorized-keys:
  - ${tls_private_key.installkey.public_key_openssh}
- name: root
  ssh_authorized_keys:
  - ${tls_private_key.installkey.public_key_openssh}
fqdn:  ${format("${var.instance_name}-master%02d", count.index + 1) }.${random_id.clusterid.hex}.${var.private_domain}
manage_resolv_conf: true
resolv_conf:
  nameservers: [ ${cidrhost(element(aws_subnet.icp_private_subnet.*.cidr_block, count.index), 2)}]
  domain: ${random_id.clusterid.hex}.${var.private_domain}
  searchdomains:
  - ${random_id.clusterid.hex}.${var.private_domain}
EOF
}

resource "null_resource" "master_install_icp" {
    depends_on=["aws_instance.icpmaster","aws_instance.bastion"]

    connection {
      host = "${element(aws_instance.icpmaster.*.private_ip,0)}"
      user = "icpdeploy"
      private_key = "${tls_private_key.installkey.private_key_pem}"
      agent = "false"
      bastion_host="${element(aws_instance.bastion.*.public_ip,0)}"
    }

    provisioner "remote-exec" {
      inline = [
        "sudo /tmp/bootstrap-node.sh -c ${aws_s3_bucket.icp_config_backup.id} -s \"bootstrap.sh functions.sh ${count.index == 0 ? "start_install.sh" : ""} ${count.index == 0 && var.enable_autoscaling ? "create_client_cert.sh" : ""}\"",
        "sudo /tmp/icp_scripts/bootstrap.sh ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdx ${local.image_package_uri != "" ? "-i ${local.image_package_uri}" : "" } -s ${var.icp_inception_image} ${length(var.patch_images) > 0 ? "-a \"${join(" ", var.patch_images)}\"" : "" }",
        "sudo /tmp/icp_scripts/start_install.sh -i ${var.icp_inception_image} -c ${aws_s3_bucket.icp_config_backup.id} -r ${aws_s3_bucket.icp_registry.id} ${length(var.patch_scripts) > 0 ? "-s \"${join(" ", var.patch_scripts)}\"" : "" }",
        "${var.enable_autoscaling ? "sudo /tmp/icp_scripts/create_client_cert.sh -i ${var.icp_inception_image} -b ${aws_s3_bucket.icp_config_backup.id}" : "echo -n" }"
      ]
  }
}

resource "null_resource" "master_install_icp4d" {
    depends_on=["null_resource.icp4d_install_package","null_resource.master_install_icp"]

    connection {
      host = "${element(aws_instance.icpmaster.*.private_ip,0)}"
      user = "icpdeploy"
      private_key = "${tls_private_key.installkey.private_key_pem}"
      agent = "false"
      bastion_host="${element(aws_instance.bastion.*.public_ip,0)}"
    }

    provisioner "remote-exec" {
      inline = [
        "sudo bash /tmp/icp_scripts/generate_wdp_conf.sh ${aws_lb.icp-console.dns_name} ${aws_lb.icp-console.dns_name} ${aws_lb.icp-console.dns_name} icpdeploy '/root/.ssh/installkey' ${local.efs_icp4d_mountpoints}",
        "sudo bash /tmp/icp_scripts/install_icp4d.sh ${local.image_icp4d_uri} ${var.image_location_icp4d}"
      ]
    }
}

# upload icp4d install package and kick off install

resource "aws_instance" "icpproxy" {
  depends_on = [
    "aws_route_table_association.a",
    "null_resource.icp_install_package",
    "aws_s3_bucket_object.bootstrap",
    "aws_s3_bucket_object.docker_install_package"
  ]

  count         = "${var.proxy["nodes"]}"
  key_name      = "${var.key_name}"
  ami           = "${var.proxy["ami"] != "" ? var.proxy["ami"] : local.default_ami }"
  instance_type = "${var.proxy["type"]}"

  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"

  ebs_optimized = "${var.proxy["ebs_optimized"]}"
  root_block_device {
    volume_size = "${var.proxy["disk"]}"
  }

  # docker direct-lvm volume
  ebs_block_device {
    device_name       = "/dev/xvdx"
    volume_size       = "${var.proxy["docker_vol"]}"
    volume_type       = "gp2"
  }

  network_interface {
    network_interface_id = "${element(aws_network_interface.proxyvip.*.id, count.index)}"
    device_index = 0
  }

  iam_instance_profile = "${local.iam_ec2_instance_profile_id}"

  tags = "${merge(
    var.default_tags,
    map("Name", "${format("${var.instance_name}-${random_id.clusterid.hex}-proxy%02d", count.index + 1) }"),
    map("kubernetes.io/cluster/${random_id.clusterid.hex}", "${random_id.clusterid.hex}")
  )}"


  user_data = <<EOF
#cloud-config
packages:
- unzip
- python
rh_subscription:
  enable-repo: rhui-REGION-rhel-server-optional
write_files:
- path: /tmp/bootstrap-node.sh
  permissions: '0755'
  encoding: b64
  content: ${base64encode(file("${path.module}/scripts/bootstrap-node.sh"))}
bootcmd:
- sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
- setenforce permissive
runcmd:
- /tmp/bootstrap-node.sh -c ${aws_s3_bucket.icp_config_backup.id} -s "bootstrap.sh"
- /tmp/icp_scripts/bootstrap.sh ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdx ${local.image_package_uri != "" ? "-i ${local.image_package_uri}" : "" } -s ${var.icp_inception_image} ${length(var.patch_images) > 0 ? "-a \"${join(" ", var.patch_images)}\"" : "" }
users:
- default
- name: icpdeploy
  groups: [ wheel ]
  sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
  shell: /bin/bash
  ssh-authorized-keys:
  - ${tls_private_key.installkey.public_key_openssh}
fqdn: ${format("${var.instance_name}-proxy%02d", count.index + 1)}.${random_id.clusterid.hex}.${var.private_domain}
manage_resolv_conf: true
resolv_conf:
  nameservers: [ ${cidrhost(element(aws_subnet.icp_private_subnet.*.cidr_block, count.index), 2)}]
  domain: ${random_id.clusterid.hex}.${var.private_domain}
  searchdomains:
  - ${random_id.clusterid.hex}.${var.private_domain}
EOF
}

resource "aws_instance" "icpmanagement" {
  depends_on = [
    "aws_route_table_association.a",
    "null_resource.icp_install_package",
    "aws_s3_bucket_object.bootstrap",
    "aws_s3_bucket_object.docker_install_package"
  ]

  count         = "${var.management["nodes"]}"
  key_name      = "${var.key_name}"
  ami           = "${var.management["ami"] != "" ? var.management["ami"] : local.default_ami }"
  instance_type = "${var.management["type"]}"
  subnet_id     = "${element(aws_subnet.icp_private_subnet.*.id, count.index)}"
  vpc_security_group_ids = [
    "${aws_security_group.default.id}"
  ]

  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"

  ebs_optimized = "${var.management["ebs_optimized"]}"
  root_block_device {
    volume_size = "${var.management["disk"]}"
  }

  # docker direct-lvm volume
  ebs_block_device {
    device_name       = "/dev/xvdx"
    volume_size       = "${var.management["docker_vol"]}"
    volume_type       = "gp2"
  }

  iam_instance_profile = "${local.iam_ec2_instance_profile_id}"

  tags = "${merge(
    var.default_tags,
    map("Name",  "${format("${var.instance_name}-${random_id.clusterid.hex}-management%02d", count.index + 1) }"),
    map("kubernetes.io/cluster/${random_id.clusterid.hex}", "${random_id.clusterid.hex}")
  )}"

  user_data = <<EOF
#cloud-config
packages:
- unzip
- python
rh_subscription:
  enable-repo: rhui-REGION-rhel-server-optional
write_files:
- path: /tmp/bootstrap-node.sh
  permissions: '0755'
  encoding: b64
  content: ${base64encode(file("${path.module}/scripts/bootstrap-node.sh"))}
bootcmd:
- sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
- setenforce permissive
runcmd:
- /tmp/bootstrap-node.sh -c ${aws_s3_bucket.icp_config_backup.id} -s "bootstrap.sh"
- /tmp/icp_scripts/bootstrap.sh ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdx ${local.image_package_uri != "" ? "-i ${local.image_package_uri}" : "" } -s ${var.icp_inception_image} ${length(var.patch_images) > 0 ? "-a \"${join(" ", var.patch_images)}\"" : "" }
users:
- default
- name: icpdeploy
  groups: [ wheel ]
  sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
  shell: /bin/bash
  ssh-authorized-keys:
  - ${tls_private_key.installkey.public_key_openssh}
fqdn: ${format("${var.instance_name}-management%02d", count.index + 1) }.${random_id.clusterid.hex}.${var.private_domain}
manage_resolv_conf: true
resolv_conf:
  nameservers: [ ${cidrhost(element(aws_subnet.icp_private_subnet.*.cidr_block, count.index), 2)}]
  domain: ${random_id.clusterid.hex}.${var.private_domain}
  searchdomains:
  - ${random_id.clusterid.hex}.${var.private_domain}
EOF
}

resource "aws_instance" "icpva" {
  depends_on = [
    "aws_route_table_association.a",
    "null_resource.icp_install_package",
    "aws_s3_bucket_object.bootstrap",
    "aws_s3_bucket_object.docker_install_package"
  ]

  count         = "${var.va["nodes"]}"
  key_name      = "${var.key_name}"
  ami           = "${var.va["ami"] != "" ? var.va["ami"] : local.default_ami }"
  instance_type = "${var.va["type"]}"
  subnet_id     = "${element(aws_subnet.icp_private_subnet.*.id, count.index)}"
  vpc_security_group_ids = [
    "${aws_security_group.default.id}"
  ]

  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"

  ebs_optimized = "${var.va["ebs_optimized"]}"
  root_block_device {
    volume_size = "${var.va["disk"]}"
  }

  # docker direct-lvm volume
  ebs_block_device {
    device_name       = "/dev/xvdx"
    volume_size       = "${var.va["docker_vol"]}"
    volume_type       = "gp2"
  }

  iam_instance_profile = "${local.iam_ec2_instance_profile_id}"

  tags = "${merge(
    var.default_tags,
    map("Name",  "${format("${var.instance_name}-${random_id.clusterid.hex}-va%02d", count.index + 1) }"),
    map("kubernetes.io/cluster/${random_id.clusterid.hex}", "${random_id.clusterid.hex}")
  )}"

  user_data = <<EOF
#cloud-config
packages:
- unzip
- python
rh_subscription:
  enable-repo: rhui-REGION-rhel-server-optional
write_files:
- path: /tmp/bootstrap-node.sh
  permissions: '0755'
  encoding: b64
  content: ${base64encode(file("${path.module}/scripts/bootstrap-node.sh"))}
bootcmd:
- sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
- setenforce permissive
runcmd:
- /tmp/bootstrap-node.sh -c ${aws_s3_bucket.icp_config_backup.id} -s "bootstrap.sh"
- /tmp/icp_scripts/bootstrap.sh ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdx ${local.image_package_uri != "" ? "-i ${local.image_package_uri}" : "" } -s ${var.icp_inception_image} ${length(var.patch_images) > 0 ? "-a \"${join(" ", var.patch_images)}\"" : "" }
users:
- default
- name: icpdeploy
  groups: [ wheel ]
  sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
  shell: /bin/bash
  ssh-authorized-keys:
  - ${tls_private_key.installkey.public_key_openssh}
fqdn: ${format("${var.instance_name}-va%02d", count.index + 1) }.${random_id.clusterid.hex}.${var.private_domain}
manage_resolv_conf: true
resolv_conf:
  nameservers: [ ${cidrhost(element(aws_subnet.icp_private_subnet.*.cidr_block, count.index), 2)}]
  domain: ${random_id.clusterid.hex}.${var.private_domain}
  searchdomains:
  - ${random_id.clusterid.hex}.${var.private_domain}
EOF

}

resource "aws_instance" "icpnodes" {
  count         = "${var.worker["nodes"]}"

  # Make sure the nodes will have internet access before provisioning
  depends_on = [
    "aws_route_table_association.a",
    "null_resource.icp_install_package",
    "aws_s3_bucket_object.bootstrap",
    "aws_s3_bucket_object.docker_install_package"
  ]

  key_name      = "${var.key_name}"
  ami           = "${var.worker["ami"] != "" ? var.worker["ami"] : local.default_ami }"
  instance_type = "${var.worker["type"]}"
  subnet_id     = "${element(aws_subnet.icp_private_subnet.*.id, count.index)}"
  vpc_security_group_ids = [
    "${aws_security_group.default.id}"
  ]

  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"

  iam_instance_profile = "${local.iam_ec2_instance_profile_id}"

  ebs_optimized = "${var.worker["ebs_optimized"]}"
  root_block_device {
    volume_size = "${var.worker["disk"]}"
  }
  
  tags = "${merge(
    var.default_tags,
    map("Name",  "${format("${var.instance_name}-${random_id.clusterid.hex}-worker%02d", count.index + 1) }"),
    map("kubernetes.io/cluster/${random_id.clusterid.hex}", "${random_id.clusterid.hex}")
  )}"

  user_data = <<EOF
#cloud-config
packages:
- unzip
- python
rh_subscription:
  enable-repo: rhui-REGION-rhel-server-optional
write_files:
- path: /tmp/bootstrap-node.sh
  permissions: '0755'
  encoding: b64
  content: ${base64encode(file("${path.module}/scripts/bootstrap-node.sh"))}
bootcmd:
- sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
- setenforce permissive
runcmd:
- /tmp/bootstrap-node.sh -c ${aws_s3_bucket.icp_config_backup.id} -s "bootstrap.sh"
- /tmp/icp_scripts/bootstrap.sh ${local.docker_package_uri != "" ? "-p ${local.docker_package_uri}" : "" } -d /dev/xvdx ${local.image_package_uri != "" ? "-i ${local.image_package_uri}" : "" } -s ${var.icp_inception_image} ${length(var.patch_images) > 0 ? "-a \"${join(" ", var.patch_images)}\"" : "" }
disable_root: false
users:
- default
- name: icpdeploy
  groups: [ wheel ]
  sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
  shell: /bin/bash
  ssh-authorized-keys:
  - ${tls_private_key.installkey.public_key_openssh}
- name: root
  ssh_authorized_keys:
  - ${tls_private_key.installkey.public_key_openssh}
fqdn: ${format("${var.instance_name}-worker%02d", count.index + 1) }.${random_id.clusterid.hex}.${var.private_domain}
manage_resolv_conf: true
resolv_conf:
  nameservers: [ ${cidrhost(element(aws_subnet.icp_private_subnet.*.cidr_block, count.index), 2)}]
  domain: ${random_id.clusterid.hex}.${var.private_domain}
  searchdomains:
  - ${random_id.clusterid.hex}.${var.private_domain}
EOF
}

resource "aws_ebs_volume" "icpnodes_docker_ebs" {
  count = "${var.worker["nodes"]}"
  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"
  size  = "${var.worker["docker_vol"]}"
  type  = "gp2"
  tags = "${merge(
    var.default_tags,
    map("Name",  "${format("${var.instance_name}-${random_id.clusterid.hex}-worker%02d-dockerdisk", count.index + 1) }")
  )}"
}

resource "aws_volume_attachment" "icpnodes_docker_ebs_att" {
  count = "${var.worker["nodes"]}"
  device_name = "/dev/xvdx"
  volume_id   = "${element(aws_ebs_volume.icpnodes_docker_ebs.*.id,count.index)}"
  instance_id = "${element(aws_instance.icpnodes.*.id,count.index)}"
  skip_destroy = false
  force_detach = true
}

resource "aws_ebs_volume" "icpnodes_ibm_ebs" {
  count = "${var.worker["nodes"]}"
  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"
  size  = "${var.worker["ibm_vol"]}"
  type  = "gp2"
  tags = "${merge(
    var.default_tags,
    map("Name",  "${format("${var.instance_name}-${random_id.clusterid.hex}-worker%02d-ibmdisk", count.index + 1) }")
  )}"
}

resource "aws_volume_attachment" "icpnodes_ibm_ebs_att" {
  count = "${var.worker["nodes"]}"
  device_name = "/dev/xvdb"
  volume_id   = "${element(aws_ebs_volume.icpnodes_ibm_ebs.*.id,count.index)}"
  instance_id = "${element(aws_instance.icpnodes.*.id,count.index)}"
  skip_destroy = false
  force_detach = true
}

resource "aws_ebs_volume" "icpnodes_data_ebs" {
  count = "${var.icp4d_storage_efs == 0 ? var.worker["nodes"] : 0 }"
  availability_zone = "${format("%s%s", element(list(var.aws_region), count.index), element(var.azs, count.index))}"
  size  = "${var.worker["data_vol"]}"
  type  = "gp2"
  tags = "${merge(
    var.default_tags,
    map("Name",  "${format("${var.instance_name}-${random_id.clusterid.hex}-worker%02d-datadisk", count.index + 1) }")
  )}"
}

resource "aws_volume_attachment" "icpnodes_data_ebs_att" {
  count = "${var.icp4d_storage_efs == 0 ? var.worker["nodes"] : 0 }"
  device_name = "/dev/xvdc"
  volume_id   = "${element(aws_ebs_volume.icpnodes_data_ebs.*.id,count.index)}"
  instance_id = "${element(aws_instance.icpnodes.*.id,count.index)}"
  skip_destroy = false
  force_detach = true
}

output "bootmaster" {
  value = "${aws_instance.icpmaster.0.private_ip}"
}

resource "aws_network_interface" "mastervip" {
  count           = "${var.master["nodes"]}"
  subnet_id       = "${element(aws_subnet.icp_private_subnet.*.id, count.index)}"
  private_ips_count = 1

  security_groups = [
    "${compact(
        list(
          aws_security_group.default.id,
          aws_security_group.master.id,
          var.proxy["nodes"] == 0 ? aws_security_group.proxy.id : ""
      ))}"
  ]

  tags = "${merge(var.default_tags, map(
   "Name", "${format("${var.instance_name}-${random_id.clusterid.hex}-master%02d", count.index + 1) }"
 ))}"
}

resource "aws_network_interface" "proxyvip" {
  count           = "${var.proxy["nodes"]}"
  subnet_id       = "${element(aws_subnet.icp_private_subnet.*.id, count.index)}"
  private_ips_count = 1

  security_groups = [
    "${aws_security_group.default.id}",
    "${aws_security_group.proxy.id}"
  ]

  tags = "${merge(var.default_tags, map(
    "Name", "${format("${var.instance_name}-${random_id.clusterid.hex}-proxy%02d", count.index + 1) }"
  ))}"
}

resource "aws_launch_configuration" "icp_worker_lc" {
  count = "${var.enabled ? 1 : 0}"
  name          = "icp-workers-${var.cluster_id}"
  image_id      = "${var.ami}"
  key_name      = "${var.key_name}"
  instance_type = "${var.instance_type}"

  iam_instance_profile = "${var.ec2_iam_instance_profile_id}"
  associate_public_ip_address = false

  security_groups = ["${var.security_groups}"]

  ebs_optimized = true
  root_block_device {
    volume_size = "${var.worker_root_disk_size}"
  }

  # docker direct-lvm volume
  ebs_block_device {
    device_name       = "/dev/xvdx"
    volume_size       = "${var.worker_docker_vol_size}"
    volume_type       = "gp2"
  }

  user_data = <<EOF
#cloud-config
packages:
  - unzip
  - python
rh_subscription:
  enable-repo: rhui-REGION-rhel-server-optional
write_files:
  - path: /tmp/bootstrap.sh
    permissions: '0755'
    encoding: b64
    content: ${base64encode(file("${path.module}/../scripts/bootstrap.sh"))}
  - path: /tmp/bootstrap-node.sh
    permissions: '0755'
    encoding: b64
    content: ${base64encode(file("${path.module}/../scripts/bootstrap-node.sh"))}
runcmd:
  - /tmp/bootstrap-node.sh -c ${var.icp_config_s3_bucket} -s "bootstrap.sh"
  - /tmp/icp_scripts/bootstrap.sh ${var.docker_package_location != "" ? "-p ${var.docker_package_location}" : "" } -d /dev/xvdx ${var.image_location != "" ? "-i ${var.image_location}" : "" } -s ${var.icp_inception_image}
users:
  - default
  - name: icpdeploy
    groups: [ wheel ]
    sudo: [ "ALL=(ALL) NOPASSWD:ALL" ]
    shell: /bin/bash
    ssh-authorized-keys:
    - ${var.icp_pub_key}
manage_resolv_conf: true
resolv_conf:
  nameservers: [ ${cidrhost(element(var.private_subnet_cidr, count.index), 2)}]
  domain: ${var.cluster_id}.${var.private_domain}
  searchdomains:
  - ${var.cluster_id}.${var.private_domain}
EOF
}

resource "aws_autoscaling_group" "icp_worker_asg" {
  count = "${var.enabled ? 1 : 0}"
  name                 = "icp-worker-asg-${var.cluster_id}"
  launch_configuration = "${aws_launch_configuration.icp_worker_lc.name}"
  min_size             = 0
  max_size             = 20
  force_delete         = true

#  availability_zones   = "${formatlist("%v%v", var.aws_region, var.azs)}"
  vpc_zone_identifier  = ["${var.private_subnet_ids}"]

  tags = [
    {
      key                 = "kubernetes.io/cluster/${var.cluster_id}",
      value               = "${var.cluster_id}",
      propagate_at_launch = true
    }
  ]
}

resource "aws_autoscaling_lifecycle_hook" "icp_add_worker_hook" {
  count = "${var.enabled ? 1 : 0}"
  name                   = "icp-workernode-added-${var.cluster_id}"
  autoscaling_group_name = "${aws_autoscaling_group.icp_worker_asg.name}"
  default_result         = "ABANDON"
  heartbeat_timeout      = 3600
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"

  notification_metadata = <<EOF
{
  "icp_inception_image": "${var.icp_inception_image}",
  "docker_package_location": "${var.docker_package_location}",
  "image_location": "${var.image_location}",
  "cluster_backup": "icpbackup-${var.cluster_id}"
}
EOF
}

resource "aws_autoscaling_lifecycle_hook" "icp_del_worker_hook" {
  count = "${var.enabled ? 1 : 0}"
  name                   = "icp-workernode-removed-${var.cluster_id}"
  autoscaling_group_name = "${aws_autoscaling_group.icp_worker_asg.name}"
  default_result         = "ABANDON"
  heartbeat_timeout      = 3600
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"

  notification_metadata = <<EOF
{
  "icp_inception_image": "${var.icp_inception_image}",
  "docker_package_location": "${var.docker_package_location}",
  "image_location": "${var.image_location}",
  "cluster_backup": "icpbackup-${var.cluster_id}"
}
EOF
}

console.log('Loading function');

var uuid = require('uuid');
var fs = require('fs');
var yaml = require('js-yaml');
var common = require('./common.js') 
var aws = require('aws-sdk');

var job_tmpl = yaml.safeLoad(fs.readFileSync('./job-tmpl.yaml', 'utf8'));

/* sample event:
{
  "version": "0",
  "id": "52172828-61c2-5465-175b-3eea9f83d58a",
  "detail-type": "EC2 Instance-launch Lifecycle Action",
  "source": "aws.autoscaling",
  "account": "299743145002",
  "time": "2018-03-05T18:27:49Z",
  "region": "us-east-2",
  "resources": [
    "arn:aws:autoscaling:us-east-2:299743145002:autoScalingGroup:5c3812e5-af66-443a-a279-7205c12590b4:autoScalingGroupName/icp-worker-asg-1adb04ca"
  ],
  "detail": {
    "LifecycleActionToken": "230c6086-e66c-4f66-abee-ecfc9d6746b1",
    "AutoScalingGroupName": "icp-worker-asg-1adb04ca",
    "LifecycleHookName": "icp-workernode-added-1adb04ca",
    "EC2InstanceId": "i-0bbed286b7fec6d2b",
    "LifecycleTransition": "autoscaling:EC2_INSTANCE_LAUNCHING",
    "NotificationMetadata": "{\n  \"icp_inception_image\": \"registry.jkwong.cloudns.cx/ibmcom/icp-inception:2.1.0.2-rc1-ee\",\n  \"docker_package_location\": \"s3://icp-2-1-0-2-rc1/icp-docker-17.09_x86_64.bin\",\n  \"image_location\": \"\",\n  \"cluster_backup\": \"icpbackup-1adb04ca\"\n}\n"
  }
}
*/


exports.handler = (event, context, callback) => {
    console.log(JSON.stringify(event, null, 2));
    var instanceId = event.detail.EC2InstanceId;

    var scaleOut = true;
    if (typeof event.detail.LifecycleTransition === "undefined" || event.detail.LifecycleTransition === null) {
        /* not interested in this event */
        return;
    }

    common.aws_config(event.region)
    
    var promises = [];
    promises.push(common.get_instance_ip(event.region, instanceId));
    promises.push(common.get_bucket_object(process.env.s3_bucket, "ca.crt"));
    promises.push(common.get_bucket_object(process.env.s3_bucket, "lambda-cert.pem"));
    promises.push(common.get_bucket_object(process.env.s3_bucket, "lambda-key.pem"));

    return Promise.all(promises)
    .then(function(result) {
      /* try to create a batch job in kube */
      if (event.detail.LifecycleTransition === "autoscaling:EC2_INSTANCE_TERMINATING") {
        console.log("scaling down node " + result[0]);
        return create_delete_node_job(result, event);
      }

      if (event.detail.LifecycleTransition === "autoscaling:EC2_INSTANCE_LAUNCHING") {
        console.log("scaling up node " + result[0]);
        return create_add_node_job(result, event);
      }
    }).catch(function(err) {
        console.log("Error: " + err, err.stack);
        common.fail_autoscaling(event);
        return {};
    });

    //callback(null, 'Hello from Lambda');
};

function create_add_node_job(params, event) {
  var privateIp = params[0];
  var jobName = 'add-node-' + privateIp.replace(new RegExp(/\./, 'g'), "-") + "-" + uuid.v4().substring(0, 7);
  var metadataStr = unescape(event.detail.NotificationMetadata);
  var metadata = JSON.parse(metadataStr);

  job_tmpl.metadata.name = jobName;
  job_tmpl.metadata.labels.run = jobName;
  job_tmpl.metadata.labels.node_ip = privateIp.replace(new RegExp(/\./, 'g'), "-");

  // use installer image
  job_tmpl.spec.template.spec.containers[0].image = metadata.icp_inception_image;
  job_tmpl.spec.template.spec.containers[0].command = [ "/bin/bash", "-c" ];
  job_tmpl.spec.template.spec.containers[0].env = [
    {
      name: "LICENSE",
      value: "accept"
    },
    {
      name: "DOCKER_PACKAGE_LOCATION",
      value: metadata.docker_package_location
    },
    {
      name: "IMAGE_LOCATION",
      value: metadata.image_location
    },
    {
      name: "CLUSTER_BACKUP",
      value: metadata.cluster_backup
    },
    {
      name: "NODE_IP",
      value: privateIp
    },
    {
      name: "LIFECYCLEHOOKNAME",
      value: event.detail.LifecycleHookName
    },
    {
      name: "LIFECYCLEACTIONTOKEN",
      value: event.detail.LifecycleActionToken
    },
    {
      name: "ASGNAME",
      value: event.detail.AutoScalingGroupName
    },
    {
      name: "INSTANCEID",
      value: event.detail.EC2InstanceId
    },
    {
      name: "REGION",
      value: event.region
    },
    {
      name: "ANSIBLE_HOST_KEY_CHECKING",
      value: "false"
    }
  ];

  job_tmpl.spec.template.spec.containers[0].args = [
    "curl https://s3.amazonaws.com/aws-cli/awscli-bundle.zip -o /tmp/awscli-bundle.zip;" +
    "unzip /tmp/awscli-bundle.zip -d /tmp; " +
    "/tmp/awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws; " +
    "/usr/local/bin/aws s3 cp --recursive s3://${CLUSTER_BACKUP} /installer/cluster; " +
    "rm -f /installer/cluster/.install.lock; " +
    "chmod 400 /installer/cluster/ssh_key; " +
    "ansible -i /opt/ibm/cluster/hosts ${NODE_IP} --private-key /opt/ibm/cluster/ssh_key -u icpdeploy -b -m wait_for -a 'path=/var/lib/cloud/instance/boot-finished timeout=18000; " +
    "crudini --set /installer/cluster/hosts worker ${NODE_IP}; " +
    "/installer/installer.sh install -l ${NODE_IP} && " +
    "/usr/local/bin/aws --region ${REGION} autoscaling complete-lifecycle-action --lifecycle-hook-name ${LIFECYCLEHOOKNAME} --lifecycle-action-token ${LIFECYCLEACTIONTOKEN} --auto-scaling-group-name ${ASGNAME} --lifecycle-action-result CONTINUE --instance-id ${INSTANCEID} && " +
    "/usr/local/bin/aws s3 sync /installer/cluster s3://${CLUSTER_BACKUP}"
  ];

  console.log("Sending job: " + JSON.stringify(job_tmpl, 2));
  return common.create_job(params[1], params[2], params[3], job_tmpl);
}

function create_delete_node_job(params, event) {
  var privateIp = params[0];
  var jobName = 'delete-node-' + privateIp.replace(new RegExp(/\./, 'g'), "-") + "-" + uuid.v4().substring(0, 7);
  var metadataStr = unescape(event.detail.NotificationMetadata);
  var metadata = JSON.parse(metadataStr);

  job_tmpl.metadata.name = jobName;
  job_tmpl.metadata.labels.run = jobName;
  job_tmpl.metadata.labels.node_ip = privateIp.replace(new RegExp(/\./, 'g'), "-");

  // use installer image
  job_tmpl.spec.template.spec.containers[0].image = metadata.icp_inception_image;
  job_tmpl.spec.template.spec.containers[0].command = [ "/bin/bash", "-c" ];
  job_tmpl.spec.template.spec.containers[0].env = [
    {
      name: "LICENSE",
      value: "accept"
    },
    {
      name: "DOCKER_PACKAGE_LOCATION",
      value: metadata.docker_package_location
    },
    {
      name: "IMAGE_LOCATION",
      value: metadata.image_location
    },
    {
      name: "CLUSTER_BACKUP",
      value: metadata.cluster_backup
    },
    {
      name: "NODE_IP",
      value: privateIp
    },
    {
      name: "LIFECYCLEHOOKNAME",
      value: event.detail.LifecycleHookName
    },
    {
      name: "LIFECYCLEACTIONTOKEN",
      value: event.detail.LifecycleActionToken
    },
    {
      name: "ASGNAME",
      value: event.detail.AutoScalingGroupName
    },
    {
      name: "INSTANCEID",
      value: event.detail.EC2InstanceId
    },
    {
      name: "REGION",
      value: event.region
    }
  ];

  job_tmpl.spec.template.spec.containers[0].args = [
    "curl https://s3.amazonaws.com/aws-cli/awscli-bundle.zip -o /tmp/awscli-bundle.zip;" +
    "unzip /tmp/awscli-bundle.zip -d /tmp; " +
    "/tmp/awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws; " +
    "aws s3 cp --recursive s3://${CLUSTER_BACKUP} /installer/cluster; " +
    "chmod 400 /installer/cluster/ssh_key; " +
    "crudini --set /installer/cluster/hosts worker ${NODE_IP}; " +
    "rm -f /installer/cluster/.install.lock; " +
    "/installer/installer.sh uninstall -l ${NODE_IP} && " +
    "aws --region ${REGION} autoscaling complete-lifecycle-action --lifecycle-hook-name ${LIFECYCLEHOOKNAME} --lifecycle-action-token ${LIFECYCLEACTIONTOKEN} --auto-scaling-group-name ${ASGNAME} --lifecycle-action-result CONTINUE --instance-id ${INSTANCEID} && " +
    "crudini --del /installer/cluster/hosts worker ${NODE_IP} && " +
    "/usr/local/bin/aws s3 sync /installer/cluster s3://${CLUSTER_BACKUP}"
  ];

  console.log("Sending job: " + JSON.stringify(job_tmpl, 2));
  return common.create_job(params[1], params[2], params[3], job_tmpl);
}

process.on('unhandledRejection', function(error) {
  console.log('Warning: unhandled promise rejection: ', error);
});
/*
var sample_event = {
      "version": "0",
      "id": "c7db91cf-5f64-9509-f033-edff7be73fe1",
      "detail-type": "EC2 Instance-launch Lifecycle Action",
      "source": "aws.autoscaling",
      "account": "299743145002",
      "time": "2018-03-26T19:44:20Z",
      "region": "us-east-2",
      "resources": [
          "arn:aws:autoscaling:us-east-2:299743145002:autoScalingGroup:a9b4e299-d7f3-415e-a750-756e5fd1a3ed:autoScalingGroupName/icp-worker-asg-88e38aae"
      ],
      "detail": {
          "LifecycleActionToken": "82e2f702-919d-4c70-927d-95b410d32d42",
          "AutoScalingGroupName": "icp-worker-asg-88e38aae",
          "LifecycleHookName": "icp-workernode-added-88e38aae",
          "EC2InstanceId": "i-01c8a9d439053b395",
          "LifecycleTransition": "autoscaling:EC2_INSTANCE_LAUNCHING",
          "NotificationMetadata": "{\n  \"icp_inception_image\": \"ibmcom/icp-inception:2.1.0.2-ee\",\n  \"docker_package_location\": \"s3://icp-2-1-0-2-rc1/icp-docker-17.09_x86_64.bin\",\n  \"image_location\": \"\",\n  \"cluster_backup\": \"icpbackup-88e38aae\"\n}\n"
      }
};

exports.handler(sample_event, null, function(err, result) {
  if (err) {
    console.log("error: " + error);
  } else {
    console.log("result: " + result);
  }
});
*/

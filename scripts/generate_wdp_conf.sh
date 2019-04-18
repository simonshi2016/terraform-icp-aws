#!/bin/bash
cluster_lb=$1
proxy_lb=$2
cluster_domain=$3
ssh_user=$4
ssh_key=$5
nfs_mount=$6
#server:/data

function getIPs {
    for i in $(cat /opt/ibm/cluster/hosts); do
    if [[ $i =~ [A-Za-z]+ ]];then
        master_count=-1
        worker_count=-1
        if [[ $i =~ master ]];then
        master_count=0
        fi
        if [[ $i =~ worker ]];then
        worker_count=0
        fi
        continue
    fi

    if [[ $master_count -ge 0 ]];then
        masters[$master_count]=$i
        ((master_count++))
    fi

    if [[ $worker_count -ge 0 ]];then
        workers[$worker_count]=$i
        ((worker_count++))
    fi
    done
}

getIPs

master4all=${#masters[@]}
for i in ${masters[@]};do
    for j in ${workers[@]};do
        if [[ "$i" == "$j" ]];then
            ((master4all--))
            break
        fi
    done
done

echo "ssh_key=${ssh_key}" > /tmp/wdp.conf
echo "virtual_ip_address_1=${cluster_lb}" >> /tmp/wdp.conf
echo "virtual_ip_address_2=${proxy_lb}" >> /tmp/wdp.conf

master1_node=${masters[0]}
prefix=""
for((i=0;i<${#masters[@]};i++));do
	if [[ $master4all -ne 0 ]];then
		prefix="master_"
	fi
	echo "${prefix}node_$((i+1))=${masters[i]}" >> /tmp/wdp.conf
	echo "${prefix}node_path_$((i+1))=/ibm" >> /tmp/wdp.conf
    ssh -o StrictHostKeyChecking=no -i ${ssh_key} "${ssh_user}@${masters[i]}" "sudo /tmp/icp_scripts/part_disk.sh /ibm /dev/xvdb"
	if [[ $master4all -eq 0 ]];then
		echo "node_data_$((i+1))=/data" >> /tmp/wdp.conf
        ssh -o StrictHostKeyChecking=no -i ${ssh_key} "${ssh_user}@${masters[i]}" "sudo /tmp/icp_scripts/part_disk.sh /data /dev/xvdc"
	fi
done

if [[ $master4all -ne 0 ]];then
    for((i=0;i<${#workers[@]};i++));do
        echo "worker_node_$((i+1))=${workers[i]}" >> /tmp/wdp.conf
        echo "worker_node_path_$((i+1))=/ibm" >> /tmp/wdp.conf
        if [[ "$nfs_mount" == "" ]] && [[ $i -lt 3 ]];then
            echo "worker_node_data_$((i+1))=/data" >> /tmp/wdp.conf
        fi
        ssh -o StrictHostKeyChecking=no -i ${ssh_key} "${ssh_user}@${workers[i]}" "sudo /tmp/icp_scripts/part_disk.sh /ibm /dev/xvdb"
        ssh -o StrictHostKeyChecking=no -i ${ssh_key} "${ssh_user}@${workers[i]}" "sudo /tmp/icp_scripts/part_disk.sh /data /dev/xvdc"
    done
fi

if [[ "$nfs_mount" != "" ]];then
    echo $nfs_mount | awk -F: '{print "nfs_server="$1"\nnfs_dir="$2}' >> /tmp/wdp.conf
fi

echo "ssh_port=22" >> /tmp/wdp.conf
echo "suppress_warning=true" >> /tmp/wdp.conf

# add cloud additional data
admin_pwd=$(grep default_admin_password /opt/ibm/cluster/config.yaml | awk -F: '{print $2}')
echo "cloud=aws" >> /tmp/wdp.conf
echo "cloud_data=${cluster_domain},${admin_pwd}" >> /tmp/wdp.conf

scp -i ${ssh_key} -o StrictHostKeyChecking=no /tmp/wdp.conf ${ssh_user}@${master1_node}:~/
ssh -i ${ssh_key} -o StrictHostKeyChecking=no ${ssh_user}@${master1_node} "sudo mkdir -p /ibm;sudo mv wdp.conf /ibm;sudo chown root:root /ibm/wdp.conf"


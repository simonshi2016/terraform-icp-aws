#!/bin/bash
image_icp4d_uri=$1
image_location_icp4d=$2

function check_install() {
    local pidFile=/var/run/icp4d.pid

    while [[ -f $pidFile ]];do
        if which docker > /dev/null 2>&1 && docker ps | grep dp-installer > /dev/null 2>&1;then
            docker_logs=$(docker logs --tail 10 dp-installer | grep -Ei 'fail' | grep -Ei 'retry' | grep -Ei 'skip')
            if [[ -n "$docker_logs" ]];then
                echo "ICP4D Installer experiencing issue and waiting for user input, You may review the installer log under /ibm/InstallPackage/tmp"
                kill -9 $(cat $pidFile)
                rm -rf $pidFile
                break
            fi
        fi
        sleep 10
    done
}

awscli=$(which aws > /dev/null 2>&1)
if [[ $? -ne 0 ]];then
    if [[ -e "/usr/local/bin/aws" ]];then
        awscli="/usr/local/bin/aws"
    fi
fi

if [[ "$awscli" != "" ]] && [[ "${image_location_icp4d}" != "" ]];then
    echo "downloading icp4d installer"
    installer_name=$(basename $image_location_icp4d)
    installer_bucket=$(dirname $image_icp4d_uri)
    ${awscli} s3 cp $image_icp4d_uri /ibm/${installer_name} --no-progress
    if [[ $? -ne 0 ]];then
        echo "error while downloading icp4d installer"
        exit 1
    fi
    if ${awscli} s3 ls ${installer_bucket} | grep "modules/";then
        echo "downloading icp4d modules"
        ${awscli} s3 sync ${installer_bucket}/modules /ibm/modules --no-progress
    fi
    cd /ibm
    chmod a+x $installer_name

    pidFile=/var/run/icp4d.pid
    rm -rf $pidFile
    echo $$ > $pidFile
    check_install &

    ./$installer_name --load-balancer --accept-license
    if [[ $? -ne 0 ]];then
        echo "error installing icp4d,please check log under /ibm/InstallPacakge/tmp for details"
        exit 1
    fi

    rm -rf $pidFile
fi

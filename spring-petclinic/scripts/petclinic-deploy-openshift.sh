#!/bin/bash
#
# Copyright (c) 2020, 2020 IBM Corporation, RedHat and others.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
### Script to deploy the one or more instances of petclinic application on openshift###
#

ROOT_DIR=.
pushd ${ROOT_DIR}
# Run the benchmark as
# SCRIPT BENCHMARK_SERVER 
# Ex of ARGS :  wobbled.os.fyre.ibm.com 2 kruize/spring_petclinic:2.2.0-jdk-11.0.8-openj9-0.21.0

NAMESPACE="openshift-monitoring"
MANIFESTS_DIR="${HOME}/benchmarks/spring-petclinic/manifests/"
DEFAULT_IMAGE="kruize/spring_petclinic:2.2.0-jdk-11.0.8-openj9-0.21.0"
PETCLINIC_REPO="${HOME}/benchmarks/spring-petclinic/scripts/"
CLUSTER_TYPE="openshift"

# Describes the usage of the script
function usage() {
	echo
	echo "Usage: $0 -s BENCHMARK_SERVER [-i SERVER_INSTANCES] [-p PETCLINIC_IMAGE] [--cpureq=CPU_REQ] [--memreq MEM_REQ] [--cpulim=CPU_LIM] [--memlim MEM_LIM] "
	exit -1
}

# Iterate through the commandline options
while getopts s:i:p:-: gopts
do
	case ${gopts} in
	-)
		case "${OPTARG}" in
			cpureq=*)
				CPU_REQ=${OPTARG#*=}
				;;
			memreq=*)
				MEM_REQ=${OPTARG#*=}
				;;
			cpulim=*)
				CPU_LIM=${OPTARG#*=}
				;;
			memlim=*)
				MEM_LIM=${OPTARG#*=}
				;;
			*)
		esac
		;;
	s)
		BENCHMARK_SERVER=${OPTARG}
		;;
	i)
		SERVER_INSTANCES="${OPTARG}"
		;;
	p)
		PETCLINIC_IMAGE="${OPTARG}"		
		;;
	esac
done

if [ -z "${BENCHMARK_SERVER}" ]; then
	echo "Do set the variable - BENCHMARK_SERVER "
	usage
	exit 1
fi

if [ -z "${SERVER_INSTANCES}" ]; then
	SERVER_INSTANCES=1
fi

if [ -z "${PETCLINIC_IMAGE}" ]; then
	PETCLINIC_IMAGE="${DEFAULT_IMAGE}"
fi

if [[ "${PETCLINIC_IMAGE}" == "kruize/spring_petclinic:2.2.0-jdk-11.0.8-openj9-0.21.0"  || "${PETCLINIC_IMAGE}" == "spring-petclinic:latest" ]]; then
	PORT=8081
else
	PORT=8080
fi

# checks if the previous command is executed successfully
# input:Return value of previous command
# output:Prompts the error message if the return value is not zero 
function err_exit() {
	if [ $? != 0 ]; then
		printf "$*"
		echo "See ${LOGFILE} for more details"
		exit -1
	fi
}

# Check if the application is running
# output: Returns 1 if the application is running else returns 0
function check_app() {
	CMD=$(oc get pods --namespace=$NAMESPACE | grep "petclinic" | grep "Running" | cut -d " " -f1)
	if [ -z "${CMD}" ]; then
		STATUS=0
	else
		STATUS=1
	fi
}

# Create multiple yamls based on instances and Update the template yamls with names and create multiple files
# input:petclinic and service-monitor yaml file
function createInstances() {
	#Create the deployments and services
	#Using inmem DB so no DB specific pods

	for(( inst=0; inst<${SERVER_INSTANCES}; inst++ ))
	do
		sed 's/name: petclinic/name: petclinic-'$inst'/g' $MANIFESTS_DIR/service-monitor.yaml > $MANIFESTS_DIR/service-monitor-$inst.yaml
		sed -i 's/petclinic-app/petclinic-app-'$inst'/g' $MANIFESTS_DIR/service-monitor-$inst.yaml
		sed -i 's/petclinic-port/petclinic-port-'$inst'/g' $MANIFESTS_DIR/service-monitor-$inst.yaml
		oc create -f $MANIFESTS_DIR/service-monitor-$inst.yaml -n $NAMESPACE
	done
	port=32334
	for(( inst=0; inst<${SERVER_INSTANCES}; inst++ ))
	do
		sed 's/petclinic-sample/petclinic-sample-'$inst'/g' $MANIFESTS_DIR/petclinic.yaml > $MANIFESTS_DIR/petclinic-$inst.yaml
		sed -i "s|${DEFAULT_IMAGE}|${PETCLINIC_IMAGE}|g" $MANIFESTS_DIR/petclinic-$inst.yaml
		sed -i 's/8081/'$PORT'/g' $MANIFESTS_DIR/petclinic-$inst.yaml
		sed -i 's/petclinic-service/petclinic-service-'$inst'/g' $MANIFESTS_DIR/petclinic-$inst.yaml
		sed -i 's/petclinic-app/petclinic-app-'$inst'/g' $MANIFESTS_DIR/petclinic-$inst.yaml
		sed -i 's/petclinic-port/petclinic-port-'$inst'/g' $MANIFESTS_DIR/petclinic-$inst.yaml
		sed -i 's/32334/'$port'/g' $MANIFESTS_DIR/petclinic-$inst.yaml
		
		# Setting cpu/mem request limits
		if [ ! -z  ${CPU_REQ} ]; then
			sed -i '28 s/^/          cpu: '$CPU_REQ'\n          memory: '$MEM_REQ'\n/' $MANIFESTS_DIR/petclinic-$inst.yaml
			sed -i '31 s/^/          cpu: '$CPU_LIM'\n          memory: '$MEM_LIM'\n/' $MANIFESTS_DIR/petclinic-$inst.yaml
		fi
		oc create -f $MANIFESTS_DIR/petclinic-$inst.yaml -n $NAMESPACE
		err_exit "Error: Issue in deploying."
		((port=port+1))

	done

	#Wait till petclinic starts
	sleep 40

	#Expose the services
	svc_list=($(oc get svc --namespace=$NAMESPACE | grep "service" | grep "petclinic" | cut -d " " -f1))
	for sv in "${svc_list[@]}"
	do
		oc expose svc/$sv --namespace=$NAMESPACE
		err_exit " Error: Issue in exposing service"
	done
	
	sleep 60
	# Check if the application is running
	check_app
	if [ "$STATUS" == 0 ]; then
		echo "Application pod did not come up"
		exit -1;
	fi
}

# Delete the petclinic deployments,services and routes if it is already present 
function stopAllInstances() {
	${PETCLINIC_REPO}/petclinic-cleanup.sh $CLUSTER_TYPE
}

# Stop all petclinic related instances if there are any
stopAllInstances
# Deploying instances
createInstances $SERVER_INSTANCES

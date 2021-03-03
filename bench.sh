#!/bin/bash

DIR=$(dirname $0)
BENCH_CYCLE="3"
IPERFTIME="120"
DEFAULT_PROTOCOLS=( TCP UDP HTTP FTP SCP )
function log {
	if [ "$OUTPUT_FILE" ]; then
		echo $@ | tee -a $OUTPUT_FILE
	else
		echo $@
	fi
}
function log_ts { log $(date "+%Y-%m-%d %H:%M:%S") $@; }
function info { log INFO "$@"; }
function warning { log WARNING "$@"; }
function error { log ERROR "$@"; }
function fatal { log FATAL "$@"; exit 2; }

function usage {
	echo "Usage: ./bench.sh [options]

Options:
	-c, --context: Kubeconfig context to run benchmark in (default: <current>)
	-i, --iterations: Number of benchmark iterations per protocol (default: $BENCH_CYCLE)
	-n, --node, --nodes: Nodes to run servers/benchmarks on. 2 required. (default: Detect nodes without the NoSchedule taint)
	-p, --protocol, --protocols: Protocols to benchmark (default: \"${DEFAULT_PROTOCOLS[@]}\")
	-t, --time: Time in seconds to run iperf benchmark for TCP and UDP tests (default: $IPERFTIME)
	--tag: Tag for results text file (default: <context>)
	-h, --help: This ;P"
}

while [ "$1" ]; do
	case $1 in
		-c | --context )
			shift
			CONTEXT=$1
			;;
		-i | --iterations )
			shift
			BENCH_CYCLE=$1
			;;
		-n | --node | --nodes )
			shift
			NODES=( ${NODES[@]} $1)
			;;
		-p | --protocol | --protocols )
			shift
			PROTOCOLS=( ${PROTOCOLS[@]} $1 )
			;;
		-t | --time )
			shift
			IPERFTIME=$1
			;;
		--tag )
			shift
			TAG=$1
			;;
		-h | --help )
			usage
			exit 0
			;;
		* )
			fatal "Unknown argument \"$1\""
			;;
	esac
	shift
done

if [ ! "$CONTEXT" ]; then
	CONTEXT=$(kubectl config current-context 2>/dev/null || true)
fi

if [ "$PROTOCOLS" ]; then
	for PROTO in ${PROTOCOLS[@]}; do
		if [[ ! " ${PROTOCOLS[@]} " =~ " ${PROTO} " ]]; then
			fatal "Unkown protocol: $PROTO"
		fi
	done
else
	PROTOCOLS=( ${DEFAULT_PROTOCOLS[@]} )
fi

mkdir -p ${DIR}/results/
TAG=${TAG:-${CONTEXT:-default}}
OUTPUT_FILE=$DIR/results/bench_${TAG}_$(date +%s).txt


#==============================================================================
# Pre-flight checks
#==============================================================================

function bench_kubectl {
	kubectl --context=${CONTEXT} run --restart=Never --rm \
		--labels="app=k8s-cni-benchmark,run=bench" \
		--overrides='{"apiVersion":"v1","spec":{"nodeSelector":{"kubernetes.io/hostname":"'${NODES[1]}'"}}}' $@
}

function apply_yml {
	local YAML_FILE=$1
	local NODE=$2

	cat $YAML_FILE | sed "s/s02/${NODE}/g" | kubectl --context=${CONTEXT} apply -f - > /dev/null
}

SUMMARY=""

if [ ! "${NODES}" ]; then
	NODES=( $(kubectl --context=${CONTEXT} get nodes -o json | jq -r '.items[] | select(.spec.taints == null or (.spec.taints | select(.[].effect != "NoSchedule"))) | .metadata.name') )
	if (( ${#NODES[@]} < 2 )); then
		fatal "Not enough schedulable nodes found"
	fi
elif (( ${#NODES[@]} < 2 )); then
	fatal "At least 2 nodes are requiured"
fi

#==============================================================================
# Iperf
#==============================================================================
iperf() {
	info "Starting iperf3 server"
	apply_yml kubernetes/server-iperf3.yml ${NODES[0]}

	info "Waiting for pod to be alive"
	while true; do kubectl --context=${CONTEXT} get pod|grep iperf-srv |grep Running >/dev/null && break; sleep 1; done

	# Retrieving Pod IP address
	IP=$(kubectl --context=${CONTEXT} get pod/iperf-srv -o jsonpath='{.status.podIP}')
	info "Server iperf3 is listening on $IP"
}

#===[ TCP ]=======
TCP() {
	info "Launching benchmark for TCP"
	TOT_TCP=0
	for i in $(seq 1 $BENCH_CYCLE)
	do
		RES_TCP=$(bench_kubectl bench -it --image=infrabuilder/netbench:client -- iperf3 -c $IP -O $(( $IPERFTIME / 10 )) -f m -t $IPERFTIME 2>/dev/null \
			| grep receiver| awk '{print $7}')
		TOT_TCP=$(( $TOT_TCP + $RES_TCP )) || error "Bad value RES_TCP: $RES_TCP"
		info "TCP $i/$BENCH_CYCLE : $RES_TCP Mbit/s"
		sleep 1
	done
	RES_TCP=$(( $TOT_TCP / $BENCH_CYCLE ))
	info "TCP result $RES_TCP Mbit/s"
	SUMMARY="$SUMMARY\t$RES_TCP"
}

#===[ UDP ]=======
UDP() {
	info "Launching benchmark for UDP"
	TOT_UDP=0
	TOT_JIT=0
	TOT_DROP=0
	for i in $(seq 1 $BENCH_CYCLE)
	do
		read RES_UDP JITTER_UDP DROP_UDP <<< $(bench_kubectl bench -it --image=infrabuilder/netbench:client -- iperf3 -u -b 0 -c $IP -O $(( $IPERFTIME / 10 )) -w 256K -f m -t $IPERFTIME 2>/dev/null \
			| grep receiver| sed 's/.* sec//'|awk '{print $3" "$5" "$8}' | tr -d "()%")
		TOT_UDP=$(( $TOT_UDP + $RES_UDP ))
		PART_JIT=$(printf "%.3f" $JITTER_UDP| tr -d "."| sed 's/^0*//')
		TOT_JIT=$(( $TOT_JIT + $PART_JIT ))
		TOT_DROP=$(( $TOT_DROP + $( printf "%.0f" $DROP_UDP) ))
		info "UDP $i/$BENCH_CYCLE : $RES_UDP Mbit/s ${PART_JIT}us jitter ${DROP_UDP}% drop"
		sleep 1
	done
	RES_UDP=$(( $TOT_UDP / $BENCH_CYCLE ))
	JIT_UDP=$(( $TOT_JIT / $BENCH_CYCLE ))
	DROP_UDP=$(( $TOT_DROP / $BENCH_CYCLE ))
	info "UDP result $RES_UDP Mbit/s ${JIT_UDP}us jitter ${DROP_UDP}% drop"
	SUMMARY="$SUMMARY\t$RES_UDP\t$JIT_UDP\t$DROP_UDP"
}

iperf-cleanup() {
	info "Cleaning resources"
	kubectl --context=${CONTEXT} delete -f kubernetes/server-iperf3.yml >/dev/null
}

#==============================================================================
# HTTP
#==============================================================================
HTTP() {
	info "Starting HTTP server"
	apply_yml kubernetes/server-http.yml ${NODES[0]}

	info "Waiting for pod to be alive"
	while true; do kubectl --context=${CONTEXT} get pod|grep http-srv |grep Running >/dev/null && break; sleep 1; done

	IP=$(kubectl --context=${CONTEXT} get pod/http-srv -o jsonpath='{.status.podIP}')
	info "Server HTTP is listening on $IP"

	info "Launching benchmark for HTTP"
	TOT_HTTP=0
	for i in $(seq 1 $BENCH_CYCLE)
	do
		RES_HTTP=$(bench_kubectl bench -it --image=infrabuilder/netbench:client \
			-- curl -o /dev/null -skw "%{speed_download}" http://$IP/10G.dat 2>/dev/null| sed 's/\..*//' )
		TOT_HTTP=$(( $TOT_HTTP + RES_HTTP ))
		info "HTTP $i/$BENCH_CYCLE : $(( $RES_HTTP * 8 / 1024/ 1024 )) Mbit/s"
		sleep 1
	done
	RES_HTTP=$(( $TOT_HTTP * 8 / $BENCH_CYCLE / 1024 / 1024 ))

	info "HTTP result $RES_HTTP Mbit/s"
	SUMMARY="$SUMMARY\t$RES_HTTP\t"

	info "Cleaning resources"
	kubectl --context=${CONTEXT} delete -f kubernetes/server-http.yml >/dev/null
}


#==============================================================================
# FTP
#==============================================================================
FTP() {
	info "Starting FTP server"
	apply_yml kubernetes/server-ftp.yml ${NODES[0]}

	info "Waiting for pod to be alive"
	while true; do kubectl --context=${CONTEXT} get pod|grep ftp-srv |grep Running >/dev/null && break; sleep 1; done

	IP=$(kubectl --context=${CONTEXT} get pod/ftp-srv -o jsonpath='{.status.podIP}')
	info "Server FTP is listening on $IP"

	info "Launching benchmark for FTP with $BENCH_CYCLE cycles"
	TOT_FTP=0
	for i in $(seq 1 $BENCH_CYCLE)
	do
		RES_FTP=$(bench_kubectl bench -it --image=infrabuilder/netbench:client \
			-- curl -o /dev/null -skw "%{speed_download}" ftp://$IP/10G.dat 2>/dev/null| sed 's/\..*//' )
		TOT_FTP=$(( $TOT_FTP + RES_FTP ))
		info "FTP $i/$BENCH_CYCLE : $(( $RES_FTP * 8 / 1024/ 1024 )) Mbit/s"
		sleep 1
	done
	RES_FTP=$(( $TOT_FTP * 8 / $BENCH_CYCLE / 1024 / 1024 ))

	info "FTP result $RES_FTP Mbit/s"
	SUMMARY="$SUMMARY\t$RES_FTP"

	info "Cleaning resources"
	kubectl --context=${CONTEXT} delete -f kubernetes/server-ftp.yml >/dev/null
}


#==============================================================================
# SCP
#==============================================================================
SCP() {
	info "Starting SCP server"
	apply_yml kubernetes/server-ssh.yml ${NODES[0]}

	info "Waiting for pod to be alive"
	while true; do kubectl --context=${CONTEXT} get pod|grep ssh-srv |grep Running >/dev/null && break; sleep 1; done

	IP=$(kubectl --context=${CONTEXT} get pod/ssh-srv -o jsonpath='{.status.podIP}')
	info "Server SCP is listening on $IP"

	info "Launching benchmark for SCP with $BENCH_CYCLE cycles"
	TOT_SCP=0
	for i in $(seq 1 $BENCH_CYCLE)
	do
		RES_SCP=$(bench_kubectl bench -it --image=infrabuilder/netbench:client \
			-- sshpass -p root scp  -o UserKnownHostsFile=/dev/null \
			-o StrictHostKeyChecking=no -v root@$IP:/root/10G.dat ./ 2>/dev/null\
			| grep "Bytes per second" |sed -e 's/.*received //' -e 's/\..*$//' )
		TOT_SCP=$(( $TOT_SCP + RES_SCP ))
		info "SCP $i/$BENCH_CYCLE : $(( $RES_SCP * 8 / 1024/ 1024 )) Mbit/s"
		sleep 1
	done
	RES_SCP=$(( $TOT_SCP * 8 / $BENCH_CYCLE / 1024 / 1024 ))

	info "SCP result $RES_SCP Mbit/s"
	SUMMARY="$SUMMARY\t$RES_SCP"

	info "Cleaning resources"
	kubectl --context=${CONTEXT} delete -f kubernetes/server-ssh.yml >/dev/null
}

declare -A IPERF_PROTOS=(
	[TCP]=""
	[UDP]=""
)

for PROTO in ${!IPERF_PROTOS[@]}; do
	if [[ " ${PROTOCOLS[@]} " =~ " $PROTO " ]]; then
		IPERF_PROTOS[$PROTO]=true
	fi
done

IPERF_SETUP=""
for PROTO in ${PROTOCOLS[@]}; do
	if [ "${IPERF_PROTOS[$PROTO]}" ]; then
		if [ ! "$IPERF_SETUP" ]; then
			iperf
			IPERF_SETUP=true
		fi

		$PROTO

		IPERF_PROTOS[$PROTO]=""
		if [ ! ${IPERF_PROTOS[@]} ]; then
			iperf-cleanup
		fi
	else
		$PROTO
	fi
done


#==============================================================================
# SUMMARY
#==============================================================================
log "========================================================================="
log -e "SUMMARY: $SUMMARY"
log "========================================================================="

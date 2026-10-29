# 人工构造的健康集群，仅供测试；不调用真实 kubectl 或网络。
# 每次替换使用独立的临时 kubeconfig；并行目标不能共享模拟状态。
state="$(dirname "$0")/deployment-state-$(basename "$KUBECONFIG")"
case "$1 $2" in
  'set image')
    printf '%s\n%s\n%s\n' "${3#deployment/}" "${4%%=*}" "${4#*=}" > "$state"
    echo '模拟镜像替换完成'
    exit 0 ;;
  'rollout status') echo '模拟 rollout 完成'; exit 0 ;;
  'get events') echo '{"items":[]}'; exit 0 ;;
esac
[ -f "$state" ] || { echo '缺少模拟部署状态' >&2; exit 1; }
deployment=$(sed -n '1p' "$state")
container=$(sed -n '2p' "$state")
image=$(sed -n '3p' "$state")
template="{\"metadata\":{\"labels\":{\"app\":\"$deployment\"}},\"spec\":{\"containers\":[{\"name\":\"$container\",\"image\":\"$image\",\"readinessProbe\":{\"httpGet\":{\"path\":\"/healthz\",\"port\":8080}}}]}}"
case "$1 $2" in
  'get deployment')
    printf '%s\n' "{\"metadata\":{\"name\":\"$deployment\",\"uid\":\"deployment-1\",\"generation\":1},\"spec\":{\"replicas\":1,\"selector\":{\"matchLabels\":{\"app\":\"$deployment\"}},\"template\":$template},\"status\":{\"observedGeneration\":1,\"replicas\":1,\"updatedReplicas\":1,\"readyReplicas\":1,\"availableReplicas\":1}}" ;;
  'get replicasets')
    printf '%s\n' "{\"items\":[{\"metadata\":{\"name\":\"$deployment-rs\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"uid\":\"deployment-1\",\"kind\":\"Deployment\",\"controller\":true}]},\"spec\":{\"template\":$template}}]}" ;;
  'get pods')
    printf '%s\n' "{\"items\":[{\"metadata\":{\"name\":\"$deployment-pod\",\"uid\":\"pod-1\",\"ownerReferences\":[{\"uid\":\"rs-1\",\"kind\":\"ReplicaSet\",\"controller\":true}]},\"spec\":{\"containers\":[{\"name\":\"$container\",\"image\":\"$image\"}]},\"status\":{\"phase\":\"Running\",\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}],\"containerStatuses\":[{\"name\":\"$container\",\"ready\":true,\"restartCount\":0,\"state\":{\"running\":{}}}]}}]}" ;;
  *) echo '未定义的模拟 kubectl 命令' >&2; exit 1 ;;
esac

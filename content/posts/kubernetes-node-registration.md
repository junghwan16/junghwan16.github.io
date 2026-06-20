---
title: "쿠버네티스 노드는 control plane이 찾아내는 게 아니다"
url: "/infra/kubernetes/2026/05/17/kubernetes-node-registration/"
date: 2026-05-17 10:00:00 +0900
categories: [infra, kubernetes]
---

`kubectl get nodes`를 치면 노드 목록이 쭉 뜬다. 너무 당연해서 한 번도 의심해본 적이 없는데, 가만히 생각해보면 이상하다.

쿠버네티스는 내 EC2 인스턴스 ID도, AWS 계정도 모른다. 그런데 어떻게 "이 서버가 내 클러스터의 노드"라는 걸 알까? 누가 등록하는 걸까? control plane이 네트워크를 스캔해서 살아 있는 서버를 찾는 걸까?

답부터 말하면 반대다. control plane은 worker를 찾으러 다니지 않는다. worker가 스스로 찾아와서 "저 등록할게요" 하고 손을 든다. 이 비대칭성이 노드 등록을 이해하는 출발점이다.

아래에서는 그 "손을 드는 과정"을 한 단계씩 따라간다.

---

## 1. "노드"는 서버가 아니다, 등록된 실행 환경이다

운영 환경에서 노드는 보통 서버 인스턴스다. EC2, GCE VM, 온프레미스 물리 서버, 사내 VM 같은 것들. 그래서 "서버 = 노드"라고 생각하게 된다.

하지만 쿠버네티스 관점에서 보면 서버 자체는 노드가 아니다. 그 서버 위에 필요한 구성요소가 깔리고 **API Server에 등록되었을 때** 비로소 Node가 된다.

```
서버 인스턴스
  + kubelet
  + container runtime (containerd 등)
  + 네트워크 설정 (CNI)
  + API Server 접속 인증 정보 (kubeconfig / 부트스트랩 토큰)
  = Kubernetes Node
```

즉, Node는 "서버 그 자체"라기보다 **클러스터에 등록된 서버 실행 환경**이다. 등록이 풀리면 서버는 그대로 살아 있어도 노드가 아니게 된다. 반대로 같은 서버에 다른 kubeconfig를 깔면 다른 클러스터의 노드가 된다.

이 구분이 필요한 이유는, "노드를 추가한다"는 작업의 정체가 곧 **"이 서버에서 kubelet을 API Server에 붙인다"**라는 뜻이기 때문이다.

---

## 2. 세 대의 리눅스 서버에서 시작해보자

예시로, 깡통 서버 3대로 클러스터를 만들어본다.

```
server-1   10.0.0.11
server-2   10.0.0.12
server-3   10.0.0.13
```

이 시점에서 세 대는 그냥 Linux 서버다. SSH 들어가서 `ls` 치는 것 외에 쿠버네티스적인 것은 아무것도 없다.

여기에 클러스터를 올린다는 건 보통 이런 역할 분담을 의미한다.

```
server-1
  └─ control plane
      ├─ kube-apiserver       (REST API의 단일 진입점)
      ├─ etcd                  (클러스터의 모든 상태가 저장됨)
      ├─ kube-scheduler        (Pod을 어느 노드에 둘지 결정)
      └─ kube-controller-manager

server-2 / server-3
  └─ worker
      ├─ kubelet               (이 노드의 에이전트)
      ├─ containerd            (실제 컨테이너 실행)
      └─ kube-proxy            (Service 네트워킹)
```

여기서 노드 등록의 주인공은 **kubelet** 하나다. 다른 컴포넌트는 노드 등록 자체에는 관여하지 않는다.

---

## 3. kubelet은 무엇을 하는가

kubelet을 한 줄로 정의하면 이렇다.

> **각 서버에서 돌아가는, API Server와 통신하는 데몬.**

kubelet의 역할은 크게 두 가지다.

1. **자기 자신을 노드로 등록하고 상태를 보고한다** (이번 글의 주제)
2. **자기 노드에 배정된 Pod을 실행하고 상태를 동기화한다** (다음 단계)

그래서 server-2에 kubelet이 깔리고, kubelet이 "API Server는 10.0.0.11:6443에 있고, 인증은 이걸로 한다"는 정보를 갖게 되는 순간 다음과 같은 통신이 일어난다.

```
server-2의 kubelet
  → https://10.0.0.11:6443 의 API Server 호출
  → "나 server-2라는 노드야.
     IP는 10.0.0.12, CPU 4코어, 메모리 16Gi, 컨테이너 런타임은 containerd야.
     지금 Ready 상태야."
```

API Server는 이 요청을 받아 etcd에 Node 리소스를 만든다.

```yaml
apiVersion: v1
kind: Node
metadata:
  name: server-2
status:
  addresses:
    - type: InternalIP
      address: 10.0.0.12
  capacity:
    cpu: "4"
    memory: 16Gi
  conditions:
    - type: Ready
      status: "True"
```

그 결과, 내 노트북에서 `kubectl get nodes`를 치면 이 리소스가 보인다.

이 한 줄을 기억해두면 `kubectl get nodes`의 의미가 분명해진다. **이 명령은 실제 서버를 스캔하는 게 아니다.** etcd에 저장된 Node 리소스를 읽어올 뿐이다. 그래서 서버가 죽어도 한동안 `kubectl get nodes`에는 그대로 보인다 — kubelet이 heartbeat를 끊고 일정 시간이 지나야 NotReady로 바뀐다.

---

## 4. 그런데 kubelet은 처음에 API Server와 어떻게 인증을 트는가

여기서 한 가지 미묘한 문제가 있다. **노드를 등록하려면 API Server에 인증해야 하고, 인증하려면 클라이언트 인증서가 있어야 한다. 그런데 그 인증서는 누가 발급해주는가?**

이게 신규 노드의 닭과 달걀 문제다. 아직 클러스터의 일원이 아닌 서버가 어떻게 클러스터 인증서를 받을 수 있을까?

해결은 **부트스트랩 토큰(bootstrap token)** 으로 한다. 흐름은 이렇다.

```
1. control plane에서 짧은 수명의 토큰 발급
   ex) abcdef.0123456789abcdef

2. worker 서버는 이 토큰만 가지고 API Server에 접속
   "저는 아직 정식 인증서가 없어요. 이 토큰으로 일단 통과시켜주세요."

3. kubelet이 자기 키페어를 만들고 CSR(인증서 서명 요청)을 제출

4. control plane이 CSR을 승인 → 정식 클라이언트 인증서 발급
   (kubeadm 환경에서는 자동 승인 컨트롤러가 처리)

5. 이후부터 kubelet은 그 인증서로 API Server와 통신
```

이 과정이 **TLS bootstrap**이고, kubelet 인증서가 만료되기 전에 자동으로 갱신하는 메커니즘이 **certificate rotation**이다. 흔히 `kubeadm join` 한 줄로 가려져 있어서 못 보고 지나치는데, 실제로는 이 절차가 매 노드마다 일어난다.

---

## 5. kubeadm으로 손에 잡히게 보기

이론을 한 번 코드로 내리면 흐름이 보인다. server-1에서 control plane 초기화.

```bash
sudo kubeadm init --apiserver-advertise-address=10.0.0.11
```

이 명령이 server-1 위에 control plane 전체를 띄운다.

```
server-1
  ├─ kube-apiserver
  ├─ etcd
  ├─ kube-scheduler
  ├─ kube-controller-manager
  ├─ kubelet            ← control plane 노드에도 kubelet은 깔린다
  └─ containerd
```

마지막에 kubeadm은 join 명령을 출력해준다.

```bash
sudo kubeadm join 10.0.0.11:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:1a2b3c...
```

여기 들어 있는 두 가지를 다시 보자.

- `--token`: 위에서 말한 부트스트랩 토큰. 이걸로 첫 핸드셰이크를 한다.
- `--discovery-token-ca-cert-hash`: worker가 **이상한 API Server에 속지 않기 위해** 사용한다. "내가 붙으려는 API Server의 CA 인증서 해시가 이 값과 일치해야 한다"는 검증값이다.

이 두 개는 짝으로 필요하다. 토큰만 있으면 worker가 가짜 API Server에 붙을 수 있고, 해시만 있으면 정작 등록을 할 수 없다.

이 명령을 server-2, server-3에서 실행하면 각 서버의 kubelet이 위의 TLS bootstrap을 거쳐 API Server에 자기를 등록한다.

```bash
# server-2
sudo kubeadm join 10.0.0.11:6443 --token ... --discovery-token-ca-cert-hash sha256:...

# server-3
sudo kubeadm join 10.0.0.11:6443 --token ... --discovery-token-ca-cert-hash sha256:...
```

이제 노트북에 kubeconfig를 가져와서 보면:

```
$ kubectl get nodes
NAME       STATUS   ROLES           AGE
server-1   Ready    control-plane   10m
server-2   Ready    <none>          8m
server-3   Ready    <none>          8m
```

세 줄이 다 등록까지 마쳤다는 뜻이다.

---

## 6. 클라우드 환경에서는 어떻게 다른가

EC2, GKE 같은 매니지드/클라우드 환경에서도 본질은 같다. **여전히 kubelet이 자기를 등록한다.** 다만 부트스트래핑이 자동화돼서 안 보이는 것뿐이다.

- **EKS / GKE / AKS**: 노드 그룹을 만들면 클라우드가 인스턴스를 띄우면서 user-data에 kubelet 설치 + 부트스트랩 토큰 주입 + `systemctl start kubelet`까지 다 넣어준다. 부팅 끝나면 자동으로 join.
- **cloud-controller-manager**: 등록된 Node 리소스에 클라우드 메타데이터를 채워준다. 인스턴스 타입, 가용 영역(zone), 외부 IP 같은 것들. 그래서 `kubectl get nodes -o wide`로 `m5.large`나 `ap-northeast-2a` 같은 정보가 보이는 거다.
- **karpenter, cluster autoscaler**: "Pod이 부족하다"는 신호를 받으면 클라우드 API로 새 인스턴스를 띄운다. 그 인스턴스는 위 과정으로 알아서 노드로 합류한다.

즉, "스케일 아웃"이라는 건 결국 **새 VM을 띄우고 그 VM의 kubelet이 API Server에 join하게 만드는 일**이다.

---

## 7. 등록 이후 — 왜 control plane은 worker에 명령을 "푸시"하지 않는가

노드 등록 그 자체는 여기서 끝이다. 그런데 등록 이후의 동작도 같은 원리의 연장선이라 짚고 가는 게 좋다.

`kubectl apply -f deployment.yaml`을 했을 때 무슨 일이 벌어지는가?

```
1. kubectl → API Server: "이 Deployment를 저장해줘"
2. API Server → etcd: 저장
3. Deployment Controller: "Pod이 부족하네, Pod 객체를 만들자"
4. Scheduler: "이 Pod는 server-2가 좋겠다" → spec.nodeName = server-2 로 업데이트
5. server-2의 kubelet은 API Server를 계속 watch 중
6. "어, 내 노드(server-2)에 배정된 Pod이 새로 생겼네?" → 감지
7. kubelet → containerd: "이 이미지로 컨테이너 실행해줘"
8. containerd가 이미지 pull + 컨테이너 실행
9. kubelet이 Pod 상태(Running)를 API Server에 보고
```

흐름을 다이어그램으로 보면:

```
kubectl
   ↓
API Server  ───┐
   ↓           │  (각 노드의 kubelet이
etcd           │   이 API Server를 watch)
   ↓           │
Scheduler      │
   ↓           │
spec.nodeName ─┘
   ↓
server-2 kubelet  → containerd  → 컨테이너 실행
```

여기서 볼 부분은, control plane이 server-2에게 **명령을 push하지 않는다**는 점이다. server-2의 kubelet이 API Server를 계속 **watch**하면서 "내 노드 이름이 박힌 Pod이 새로 생겼는가?"를 보고 있다가, 자기 일이 생기면 가져다 실행한다.

이 모델이 주는 효과가 꽤 크다.

- **방화벽 경로가 줄어든다.** worker → control plane 방향(6443 포트)만 열어두면 된다. control plane → worker 방향은 (`kubectl exec`/`logs` 같은 일부 기능 빼면) 필요 없다. 사내망 / 사설 서브넷에 worker를 두기 좋다.
- **장애 격리.** control plane이 잠깐 죽어도 worker에서 이미 떠 있는 Pod은 계속 돈다. kubelet은 마지막으로 본 상태를 가지고 컨테이너를 유지한다.
- **확장성.** "control plane이 수천 개 worker에 명령을 뿌리는" 구조라면 fan-out이 병목이 된다. 반대로 "각 worker가 자기 일만 본다"는 구조는 worker 수가 늘어도 control plane 부담이 선형으로만 증가한다.
- **재시도 지점이 줄어든다.** 명령을 "보냈는데 도착 못 했을 때" 같은 상태를 따로 추적하지 않는다. etcd의 desired state가 기준이고, worker는 그걸 보고 reconcile한다.

한 줄로 줄이면, 쿠버네티스는 **명령 기반(imperative push) 시스템이 아니라 상태 기반(declarative pull) 시스템**이다. 등록도 worker가 자기 의지로 한다. 실행도 worker가 자기 의지로 한다.

---

## 남는 그림

- Node는 서버 그 자체가 아니라 **클러스터에 등록된 서버 실행 환경**이다.
- 등록의 주체는 **각 서버의 kubelet**이다. control plane이 노드를 찾으러 다니지 않는다.
- 첫 등록은 **부트스트랩 토큰 → TLS bootstrap → 정식 인증서**의 흐름으로 이뤄진다. `kubeadm join`이 이 절차를 한 줄로 감싼 것일 뿐이다.
- 클라우드 환경에서는 인스턴스 부팅 시점에 위 과정을 자동화한다. 본질은 같다.
- 등록 이후의 Pod 실행도 **kubelet이 API Server를 watch하는 pull 모델**이다. 이 구조 덕분에 control plane이 worker로 명령을 밀어 넣지 않아도 된다.

`kubectl get nodes`의 한 줄은 결국, "어떤 kubelet이 자기를 등록하고, 아직 heartbeat를 보내고 있다"는 사실의 표현이다.

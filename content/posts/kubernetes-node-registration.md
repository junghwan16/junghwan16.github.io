---
title: "쿠버네티스 노드는 control plane이 찾아내는 게 아니다"
url: "/infra/kubernetes/2026/05/17/kubernetes-node-registration/"
date: 2026-05-17 10:00:00 +0900
categories: [infra, kubernetes]
---

`kubectl get nodes`를 보면 노드 목록이 나온다. 그래서 control plane이 서버를 찾아다니며 등록한다고 착각하기 쉽다. 실제로는 반대다. worker 서버의 kubelet이 API Server에 접속해서 자신을 Node로 등록한다.

control plane은 서버를 스캔하지 않는다. 등록된 Node 리소스를 읽을 뿐이다.

## 서버와 Node는 다르다

서버가 있다고 바로 Kubernetes Node가 되는 것은 아니다. 서버 위에 kubelet, container runtime, 네트워크 설정, API Server 접속 정보가 있고, kubelet이 API Server에 등록해야 Node가 된다.

```text
Linux server
  + kubelet
  + containerd
  + CNI 설정
  + kubeconfig / bootstrap token
  = Kubernetes Node
```

`kubectl get nodes`는 실제 서버 목록을 조회하는 명령이 아니라, API Server에 저장된 Node 리소스를 보는 명령이다. 서버가 죽어도 즉시 사라지지 않고, heartbeat가 끊긴 뒤 NotReady로 바뀐다.

## 등록의 주체는 kubelet이다

kubelet은 각 서버에서 돌아가는 에이전트다. 두 가지 일을 한다.

- 자신을 Node로 등록하고 상태를 보고한다.
- 자기 노드에 배정된 Pod을 실행하고 상태를 동기화한다.

노드 등록은 대략 이런 요청이다.

```text
kubelet -> API Server
  "내 이름은 worker-1이고,
   IP는 10.0.0.12이고,
   CPU/메모리는 이 정도이고,
   지금 Ready 상태다."
```

API Server는 이 정보를 Node 리소스로 저장한다.

```yaml
apiVersion: v1
kind: Node
metadata:
  name: worker-1
status:
  addresses:
    - type: InternalIP
      address: 10.0.0.12
```

## 처음 인증은 bootstrap token으로 한다

새 worker는 아직 클러스터 인증서를 갖고 있지 않다. 그런데 API Server에 등록하려면 인증이 필요하다. 이 닭과 달걀 문제를 TLS bootstrap으로 푼다.

```text
1. control plane에서 짧은 수명의 bootstrap token 발급
2. worker의 kubelet이 token으로 API Server에 접속
3. kubelet이 CSR을 제출
4. CSR 승인 후 정식 client certificate 발급
5. 이후 kubelet은 그 인증서로 통신
```

`kubeadm join` 명령이 이 과정을 감춘다.

```bash
kubeadm join 10.0.0.11:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:...
```

`--token`은 첫 인증을 위한 값이고, `--discovery-token-ca-cert-hash`는 worker가 가짜 API Server에 붙지 않도록 CA를 검증하는 값이다.

## 클라우드에서도 원리는 같다

EKS, GKE, AKS 같은 환경에서도 본질은 같다. 노드 그룹이나 오토스케일러가 VM을 띄우고, user data나 node image가 kubelet 설정을 넣어준다. 부팅한 kubelet이 API Server에 join한다.

cloud controller manager는 등록된 Node에 instance type, zone, provider ID 같은 클라우드 메타데이터를 채운다. 오토스케일러나 Karpenter는 새 인스턴스를 만들 뿐이고, 최종 등록은 여전히 kubelet이 한다.

## Pod 실행도 pull 모델이다

등록 이후에도 control plane이 worker에 직접 명령을 push하지 않는다.

```text
kubectl apply
  -> API Server에 Deployment 저장
  -> controller가 Pod 생성
  -> scheduler가 spec.nodeName 설정
  -> 해당 노드의 kubelet이 watch로 감지
  -> kubelet이 containerd에 실행 요청
```

kubelet은 API Server를 계속 watch하다가 자기 노드에 배정된 Pod을 발견하면 실행한다. 이 방향을 이해하면 방화벽과 네트워크 요구사항도 자연스럽다. worker가 API Server에 붙을 수 있어야 한다.

## 남는 그림

노드 추가는 "control plane이 서버를 발견하는 일"이 아니다. **서버 위의 kubelet이 인증을 얻고 API Server에 자신을 등록하는 일**이다. `kubectl get nodes`는 그 결과로 저장된 Node 리소스를 보는 명령이다.

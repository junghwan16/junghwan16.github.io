---
layout: single
title: "gatewayRoutes는 무슨 설정인가: Helm values에서 Istio VirtualService까지"
date: 2026-02-11 23:00:00 +0900
categories: [infra, kubernetes]
---

> `values.prod.yaml`에 `gatewayRoutes`라는 설정이 있는데, 이게 뭔지 모르고 대충 복붙하면 안 될 것 같아서 공부해보려 한다.

---

## gatewayRoutes의 역할

`gatewayRoutes`는 **외부 트래픽이 클러스터 내부 서비스에 도달하기 위한 라우팅 규칙**을 정의하는 Helm values 설정이다. 이 값을 설정하면 다음과 같은 흐름으로 적용된다:

```
values.prod.yaml (gatewayRoutes)
  → Helm template이 Istio VirtualService 매니페스트 생성
  → kubectl apply / 배포 툴이 클러스터에 적용
  → Istio Ingress Gateway(Envoy)가 Host/Path 매칭해서 내부 서비스로 라우팅
```

즉, `gatewayRoutes`에 Host와 Path 규칙을 작성하면, Helm이 이를 Istio의 **VirtualService** 리소스로 변환하고, Istio가 실제 트래픽 라우팅을 수행한다.

### 간단 예시: gatewayRoutes → VirtualService 매핑

```yaml
# values.prod.yaml
gatewayRoutes:
  - host: api.example.com
    paths:
      - path: /v1/users
        service: user-service
        port: 8080
```

위 설정이 Helm template을 거치면 아래와 같은 VirtualService가 생성된다:

```yaml
# 생성된 VirtualService (개념적 예시)
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: api-routes
spec:
  hosts:
    - api.example.com
  gateways:
    - istio-gateway
  http:
    - match:
        - uri:
            prefix: /v1/users
      route:
        - destination:
            host: user-service
            port:
              number: 8080
```

> 실제 생성되는 매니페스트는 Helm chart의 template 구조에 따라 다르다. `helm template` 명령으로 확인할 수 있다.

---

## Istio VirtualService란?

gatewayRoutes를 이해하려면 VirtualService를 알아야 한다.

- [공식 문서](https://istio.io/latest/docs/reference/config/networking/virtual-service/)
- Traffic Management 하위 목록에 VirtualService가 있고, 자주 들었던 Sidecar도 같은 카테고리에 위치해 있다.

**핵심 개념:** Istio의 VirtualService는 클라이언트가 특정 호스트(서비스)로 보낸 요청을 **실제로 어디로, 어떻게 보낼지** 결정하는 트래픽 라우팅 규칙의 집합이다. 요청이 호스트에 도달했을 때 적용할 규칙(매칭 조건)을 **순서대로 평가**하고, 조건에 맞는 경우 지정된 목적지(Destination)로 트래픽을 라우팅한다.

---

## VirtualService 주요 패턴

### 1. HTTP 요청 라우팅 및 URI 재작성

가장 일반적인 패턴으로, 특정 조건에 맞는 요청을 찾아(Match) 목적지로 보내거나 경로를 수정한다.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-route
spec:
  hosts:
    - reviews.prod.svc.cluster.local  # [1] 대상 호스트
  http:
    - name: "reviews-v2-routes"
      match:                            # [2] 조건 매칭 (OR 조건)
        - uri:
            prefix: "/wpcatalog"
        - uri:
            prefix: "/consumercatalog"
      rewrite:                          # [3] 경로 재작성
        uri: "/newcatalog"
      route:                            # [4] 목적지 지정
        - destination:
            host: reviews.prod.svc.cluster.local
            subset: v2
    - name: "reviews-v1-route"          # [5] 나머지 전부 → v1
      route:
        - destination:
            host: reviews.prod.svc.cluster.local
            subset: v1
```

| 필드 | 설명 |
|------|------|
| **hosts** | 클라이언트가 요청을 보낼 때 사용하는 주소. K8s 서비스의 FQDN 사용 권장 |
| **match** | 트래픽 필터링 조건. 여러 match 블록을 나열하면 **OR 조건**으로 동작 |
| **rewrite** | 백엔드로 전달 전 URI 수정. 사용자는 `/wpcatalog`으로 요청했지만 실제 서비스는 `/newcatalog`으로 받음 |
| **route & destination** | 매칭된 트래픽의 실제 목적지. `subset: v2`는 DestinationRule에 정의된 v2 버전 파드들 |

> 규칙은 **위에서 아래로** 평가된다. 첫 번째 규칙에 매칭되지 않은 나머지 트래픽은 두 번째 규칙(v1)으로 간다.

---

### 2. 트래픽 가중치 분산 (Traffic Splitting)

카나리 배포나 A/B 테스트를 위해 트래픽을 비율로 나누는 설정이다.

```yaml
http:
  - route:
      - destination:
          host: reviews.prod.svc.cluster.local
          subset: v2
        weight: 25   # v2로 25%
      - destination:
          host: reviews.prod.svc.cluster.local
          subset: v1
        weight: 75   # v1으로 75%
```

- **weight:** 전체 트래픽을 100으로 봤을 때 각 목적지로 보낼 비율(%). 새 버전(v2)을 소수의 사용자에게만 먼저 노출하여 안정성을 검증할 때 유용하다.

> **Argo Rollouts와의 관계:** Argo CD 자체는 GitOps 배포 도구이지만, **Argo Rollouts**를 함께 사용하면 카나리 배포 시 이 weight 값을 자동으로 조정해준다. Argo Rollouts가 Istio VirtualService의 weight를 단계적으로 변경(예: 5% → 25% → 50% → 100%)하면서 안전하게 롤아웃하는 방식이다.

---

### 3. 타임아웃 및 재시도 (Timeout & Retries)

네트워크 오류나 지연 발생 시 애플리케이션의 회복 탄력성을 높이는 설정이다.

```yaml
http:
  - route:
      - destination:
          host: ratings.prod.svc.cluster.local
          subset: v1
    retries:                              # [1] 재시도 정책
      attempts: 3
      perTryTimeout: 2s
      retryOn: gateway-error,connect-failure,refused-stream
    timeout: 5s                           # [2] 전체 타임아웃
```

| 필드 | 설명 |
|------|------|
| **retries.attempts** | 최대 재시도 횟수 (3번) |
| **retries.perTryTimeout** | 각 재시도마다 최대 대기 시간 (2초) |
| **retries.retryOn** | 재시도할 조건. 연결 실패나 서비스 불가 같은 특정 조건에서만 재시도 |
| **timeout** | 클라이언트가 응답을 기다리는 전체 최대 시간. 이 시간이 지나면 요청 취소 |

> **주의:** timeout은 재시도를 포함한 전체 시간이다. `perTryTimeout × attempts`가 timeout보다 크면 timeout이 우선한다.

---

### 4. 결함 주입 (Fault Injection)

실제 코드 수정 없이 의도적으로 에러나 지연을 발생시켜 시스템의 안정성을 테스트하는 설정이다. (Chaos Engineering)

```yaml
http:
  - match:
      - sourceLabels:
          env: prod               # 특정 소스에서 오는 요청만 대상
    route:
      - destination:
          host: reviews.prod.svc.cluster.local
          subset: v1
    fault:
      delay:                      # 지연 주입
        percentage:
          value: 0.1              # 0.1% 요청에 대해
        fixedDelay: 5s            # 5초 지연
      abort:                      # 에러 주입
        percentage:
          value: 0.1              # 0.1% 요청에 대해
        httpStatus: 400           # 400 에러 반환
```

프로덕션 환경에서 소수의 트래픽에만 장애를 주입해서, 서비스가 타임아웃이나 에러를 제대로 처리하는지 검증할 수 있다.

---

## 정리

| 개념 | 설명 |
|------|------|
| **gatewayRoutes** | Helm values에서 라우팅 규칙을 선언하는 설정 |
| **VirtualService** | gatewayRoutes로부터 생성되는 Istio 리소스. 실제 트래픽 라우팅을 담당 |
| **Istio Ingress Gateway** | 외부 트래픽의 진입점. VirtualService 규칙에 따라 내부 서비스로 분배 |

결국 `gatewayRoutes`는 **"외부에서 들어오는 요청을 어떤 Host/Path 조건으로 매칭해서 어떤 내부 서비스로 보낼 것인가"**를 정의하는 설정이며, 이 값들이 Helm을 통해 Istio VirtualService로 변환되어 실제 라우팅에 적용된다.

---
title: "gatewayRoutes는 결국 VirtualService를 만든다"
url: "/infra/kubernetes/2026/02/11/gateway-routes-istio-virtualservice/"
date: 2026-02-11 23:00:00 +0900
categories: [infra, kubernetes]
---

`gatewayRoutes`라는 이름은 Istio 공식 리소스가 아니다. 보통 Helm chart가 정의한 values 키다. 이 값을 template이 읽어서 Istio `VirtualService`를 만든다.

그래서 먼저 확인할 것은 Istio 문서가 아니라 현재 chart의 template이다.

```bash
helm template . -f values.prod.yaml
```

## 흐름

```text
values.prod.yaml
  gatewayRoutes:
    - host: api.example.com
      path: /v1/users
      service: user-service
      port: 8080

        |
        v

Helm template
        |
        v

Istio VirtualService
```

개념적으로는 이런 VirtualService가 나온다.

```yaml
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

실제 필드 이름과 구조는 chart마다 다르다. `gatewayRoutes`는 약속된 표준이 아니라 values schema의 일부다.

## Gateway와 VirtualService

Istio에서 Gateway와 VirtualService는 역할이 다르다.

| 리소스 | 역할 |
|---|---|
| Gateway | 어떤 host, port, TLS 설정으로 트래픽을 받을지 정의 |
| VirtualService | 받은 요청을 어디로, 어떤 규칙으로 보낼지 정의 |

Gateway는 리스너에 가깝고, VirtualService는 라우팅 규칙에 가깝다. VirtualService의 `gateways` 필드가 둘을 연결한다.

## 복붙 전에 볼 것

- `gatewayRoutes`가 실제로 어떤 template으로 렌더링되는가?
- host가 Gateway의 host와 맞는가?
- path match가 `prefix`, `exact`, `regex` 중 무엇인가?
- rewrite가 필요한가, 백엔드가 원래 path를 기대하는가?
- destination host가 Kubernetes service 이름과 namespace를 정확히 가리키는가?
- timeout/retry가 앱의 자체 timeout과 충돌하지 않는가?

`gatewayRoutes`를 이해하려면 그 이름을 외우는 게 아니라, 배포 전 `helm template`로 어떤 VirtualService가 만들어지는지 읽어야 한다.

## 참고자료

- [Istio VirtualService](https://istio.io/latest/docs/reference/config/networking/virtual-service/)
- [Istio Gateway](https://istio.io/latest/docs/reference/config/networking/gateway/)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)

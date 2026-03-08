---
title: "클라이언트의 IP를 알아내는 방법"
url: "/backend/network/2026/02/07/client-ip-detection/"
date: 2026-02-07 13:00:00 +0900
categories: [backend, network]
---

서버 개발을 하다보면 클라이언트의 IP를 알아야할 때가 있다. TCP 연결 자체가 IP 기반이니 쉬울 것 같지만, 프로덕션 환경은 여러 홉을 거치기 때문에 생각보다 간단하지 않다.

두 가지 레이어로 나눠서 생각해야 한다:

- **TCP 관점**: 지금 내 서버 소켓에 연결한 상대(바로 앞 홉)의 IP
- **HTTP 관점**: 이 HTTP 요청을 처음 만든 원래 사용자의 IP

---

## 1. TCP 관점: 서버가 확실히 아는 IP는 Peer의 IP 뿐이다

> 패킷이 라우터/NAT를 거칠 때 L2/L3/L4 헤더가 각각 어떻게 바뀌는지는 [[패킷이 홉을 거칠 때 헤더는 어떻게 바뀌는가]] 참고.

TCP 연결이 성립되면 서버는 커널로부터 상대방 주소를 받는다. 3-way handshake가 완료되어야 데이터를 주고받을 수 있으므로 이 값은 신뢰할 수 있다. 하지만 여기서 "상대방"은 원래 사용자가 아니라 바로 앞에 있는 장비일 수 있다.

유저와 서버가 직접 연결되면 peer IP = 유저 IP지만, **프로덕션 환경에서 이런 직접 연결은 거의 없다.**

### L7 프록시를 거치면?

```
유저 (203.0.113.50)
    │
    │  TCP 연결 ①: src=203.0.113.50 → dst=ALB
    ▼
ALB (10.0.1.100)                  ← TCP 연결 ①을 종료(terminate)
    │
    │  TCP 연결 ②: src=10.0.1.100 → dst=10.0.2.50  ← 새로운 TCP 연결
    ▼
내 서버 (10.0.2.50)

서버가 보는 peer IP = 10.0.1.100 ❌ (ALB의 내부 IP)
```

L7 프록시(ALB, Nginx, HAProxy 등)는 클라이언트 연결을 받아서 끊고, 백엔드에 새로운 연결을 맺는다. 서버 입장에서 peer IP는 프록시의 IP이지 원래 클라이언트의 IP가 아니다.

> **L4 로드밸런서(NLB)는 다르다** — AWS NLB는 기본적으로 클라이언트 IP를 보존한다. 단, TLS termination을 사용하거나 뒤에 L7 프록시를 두면 다시 같은 문제가 생긴다. 클라이언트 IP 보존이 불가능한 경우 Proxy Protocol v2를 대안으로 사용할 수 있다.

---

## 2. HTTP 관점: 원 IP는 헤더로 전달된다 (스푸핑 가능)

TCP 연결이 끊겨 다시 맺어지면, 원래 클라이언트 IP를 전달하기 위해 HTTP 헤더를 사용한다.

### 대표 헤더

- `X-Forwarded-For` (XFF): Squid 캐싱 프록시에서 도입한 사실상 표준. 가장 널리 사용된다.
- `Forwarded` ([RFC 7239](https://datatracker.ietf.org/doc/html/rfc7239)): XFF를 대체하기 위해 표준화된 헤더. `for`, `by`, `host`, `proto` 파라미터를 지원한다.
- `X-Real-IP`: Nginx에서 주로 사용하는 비표준 헤더. 단일 IP만 담는다.

### X-Forwarded-For 동작 원리

프록시가 여러 개일 때가 중요하다:

```
유저 (203.0.113.50)
    │
    │  X-Forwarded-For: (없음)
    ▼
CloudFront (54.230.10.20)
    │
    │  X-Forwarded-For: 203.0.113.50           ← 유저 IP 추가
    ▼
ALB (10.0.1.100)
    │
    │  X-Forwarded-For: 203.0.113.50, 54.230.10.20  ← CloudFront IP를 append
    ▼
내 서버

XFF 체인: client, proxy1, proxy2, ...
          ←── 오래된 순서 ──→ 최근 순서
```

### 보안 함정: 클라이언트가 헤더를 조작할 수 있다

[MDN 문서](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For)에서도 강조하는 핵심이다:

```
악의적 유저 (198.51.100.99)
    │
    │  X-Forwarded-For: 1.2.3.4             ← 가짜 IP!
    ▼
ALB (10.0.1.100)
    │
    │  X-Forwarded-For: 1.2.3.4, 198.51.100.99  ← ALB는 실제 peer IP를 append
    ▼
내 서버

XFF 첫 번째 값을 쓰면?  → 1.2.3.4 ❌ 가짜!
오른쪽에서 신뢰할 수 있는 프록시를 제외하면?  → 198.51.100.99 ✅
```

원칙:
1. 내가 신뢰하는 프록시가 붙인 구간만 신뢰한다
2. 그 이전 값은 조작 가능하다고 가정한다

AWS ALB는 `routing.http.xff_header_processing.mode`로 XFF 처리 방식을 제어한다(`append`/`preserve`/`remove`).

---

## 3. 올바르게 클라이언트 IP 추출하기

### XFF 헤더가 여러 개일 수 있다

하나의 요청에 `X-Forwarded-For` 헤더가 여러 개 존재할 수 있다. 모든 헤더의 IP를 하나의 리스트로 합쳐서 처리해야 한다.

```
X-Forwarded-For: 203.0.113.50, 54.230.10.20
X-Forwarded-For: 10.0.1.100

→ [203.0.113.50, 54.230.10.20, 10.0.1.100]
```

### 원칙: 오른쪽에서부터 신뢰할 수 있는 홉을 제거

```
X-Forwarded-For: <client?>, <proxy1?>, ..., <trusted_N>, <trusted_N-1>
                  ↑ 바로 쓰면 안 됨!          ↑ 여기서부터 왼쪽으로 벗겨냄

1. XFF를 쉼표로 split
2. 오른쪽 끝부터 시작
3. 신뢰할 수 있는 프록시 IP인 동안 제거
4. 처음 만나는 "신뢰할 수 없는" IP = 클라이언트 IP
```

### Go 예제

```go
var trustedProxies = []net.IPNet{
    parseCIDR("10.0.0.0/8"),
    parseCIDR("172.16.0.0/12"),
    parseCIDR("192.168.0.0/16"),
    parseCIDR("54.230.0.0/16"), // CloudFront (예시)
}

func isTrustedProxy(ip string) bool {
    parsed := net.ParseIP(ip)
    if parsed == nil {
        return false
    }
    for _, cidr := range trustedProxies {
        if cidr.Contains(parsed) {
            return true
        }
    }
    return false
}

func ClientIP(r *http.Request) string {
    xff := r.Header.Get("X-Forwarded-For")
    if xff == "" {
        host, _, _ := net.SplitHostPort(r.RemoteAddr)
        return host
    }

    parts := strings.Split(xff, ",")
    for i := range parts {
        parts[i] = strings.TrimSpace(parts[i])
    }

    // 오른쪽부터 신뢰할 수 있는 프록시 제거
    for i := len(parts) - 1; i >= 0; i-- {
        if !isTrustedProxy(parts[i]) {
            return parts[i]
        }
    }

    host, _, _ := net.SplitHostPort(r.RemoteAddr)
    return host
}
```

> **프레임워크 지원**: Express.js는 `trust proxy` 설정으로 동일한 로직을 내장하고 있고(`req.ip`가 최종 클라이언트 IP를 반환), Nginx는 `ngx_http_realip_module`의 `set_real_ip_from` 디렉티브로 신뢰 프록시를 지정할 수 있다.

---

## 4. IP만으로는 부족한 경우

### CGNAT (Carrier-Grade NAT)

```
유저 A (100.64.0.1) ─┐
                      ├── 통신사 NAT ── 공인 IP: 203.0.113.1
유저 B (100.64.0.2) ─┘
```

모바일 통신사는 IPv4 주소 고갈로 CGNAT([RFC 6598](https://datatracker.ietf.org/doc/html/rfc6598))를 사용한다. 수천 명이 같은 공인 IP를 공유할 수 있어서, IP만으로 개별 사용자를 식별하는 것은 불가능하다.

### VPN / 프록시 사용자

VPN을 사용하면 서버는 VPN 서버의 IP를 보게 된다. 사용자의 실제 위치와 무관한 IP가 전달된다.

### IPv6

코드에서 IPv4만 가정하면 안 된다:

```go
// ❌ IPv4만 고려
ip := strings.Split(remoteAddr, ":")[0]  // IPv6 주소에서 망가짐

// ✅ net.SplitHostPort 사용
host, _, _ := net.SplitHostPort(remoteAddr)
// "203.0.113.50:8080"    → "203.0.113.50"
// "[2001:db8::1]:8080"   → "2001:db8::1"
```

---

## 체크리스트

```
□ 서버 앞에 어떤 프록시/로드밸런서가 있는지 확인
□ 각 프록시의 XFF 처리 방식 확인 (append? overwrite?)
□ 신뢰할 수 있는 프록시의 CIDR 목록 확보
□ 오른쪽에서 벗기기 로직으로 클라이언트 IP 추출 구현
□ IPv6 주소 파싱 테스트
□ XFF 스푸핑 테스트
```

---

## 요약

```
"클라이언트 IP를 알고 싶다"
        │
        ├── 프록시가 없다면?
        │       └── RemoteAddr (peer IP) = 클라이언트 IP ✅
        │
        └── 프록시가 있다면?
                │
                ├── XFF 헤더 확인
                │       │
                │       ├── 첫 번째 값을 그냥 쓰면? → ❌ 스푸핑 위험
                │       │
                │       └── 오른쪽부터 trusted proxy 제거 → ✅
                │
                └── IP만으로 부족한 경우
                        ├── CGNAT: 여러 유저가 같은 IP
                        ├── VPN: 위치 불일치
                        └── → 다른 시그널과 조합 필요
```

---

## 참고자료

- [MDN - X-Forwarded-For](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For) — XFF 헤더의 동작, 보안 주의사항
- [RFC 7239 - Forwarded HTTP Extension](https://datatracker.ietf.org/doc/html/rfc7239) — 표준 Forwarded 헤더 명세
- [RFC 6598 - Shared Address Space](https://datatracker.ietf.org/doc/html/rfc6598) — CGNAT 100.64.0.0/10 대역 정의
- [AWS - ALB HTTP Headers](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/x-forwarded-headers.html) — ALB의 XFF 처리 모드
- [AWS - NLB Target Groups](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-target-groups.html) — NLB 클라이언트 IP 보존
- [Express.js - Behind Proxies](https://expressjs.com/en/guide/behind-proxies.html) — Express trust proxy 설정
- [Nginx - ngx_http_realip_module](https://nginx.org/en/docs/http/ngx_http_realip_module.html) — Nginx 클라이언트 IP 추출 모듈

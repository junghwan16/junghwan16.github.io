---
layout: single
title: "클라이언트의 IP를 알아내는 방법"
date: 2026-02-07 13:00:00 +0900
categories: [backend, network]
---

서버 개발을 하다보면 클라이언트의 IP를 알아야할 때가 있다.

간단하게 생각하면 L4 레이어의 TCP 연결 자체가 IP 기반이기 때문에 쉽게 알 수 있을 것이라 생각이 들 수 있지만, 실제 네트워크 환경은 여러 홉을 거치기 때문에 우리가 원하는 진짜 유저의 IP를 얻는건 생각보다 쉽지 않을수도 있을 거란 생각이 들어야 합니다.

두 가지 레이어에서 생각을 분리해봐야합니다:

- TCP 관점: "지금 내 서버 소켓에 연결한 상대(바로 앞 홉)의 IP"
- HTTP 관점: "이 HTTP 요청을 '처음' 만든 원래 사용자(또는 원발신자)의 IP"

---

## 왜 광고 시스템에서 클라이언트 IP가 중요한가?

광고 업계에 처음 들어오면 "IP 하나 가지고 뭘 그렇게 신경 쓰나" 싶을 수 있다. 하지만 광고 시스템에서 IP는 돈과 직결된다.

| 용도 | IP가 틀리면 생기는 일 |
|---|---|
| **지역 타겟팅** — IP → 국가/도시 추정 → 해당 지역 광고 노출 | 서울 유저에게 부산 치킨집 광고가 뜸 |
| **프리퀀시 캡핑** — 같은 유저에게 같은 광고를 N번 이상 안 보여주기 | 프록시 IP로 뭉쳐서 캡핑이 안 먹힘 |
| **클릭 사기 탐지** — 같은 IP에서 비정상적 클릭 패턴 감지 | 사기꾼 IP를 못 잡거나, 정상 유저를 오판 |
| **OpenRTB 입찰** — SSP → DSP 입찰 요청의 `device.ip` 필드에 유저 IP 포함 | DSP가 잘못된 IP로 입찰 → 광고주 예산 낭비 |

```
유저 브라우저 (IP: 203.0.113.50)
       │
       │  ① 광고 지면이 있는 웹페이지 로드
       ▼
  퍼블리셔 웹서버
       │
       │  ② 광고 슬롯에 대해 Ad Request 발생
       ▼
  SSP (Supply-Side Platform)          ← 여기서 유저 IP를 수집해야 함
       │
       │  ③ OpenRTB Bid Request (유저 IP 포함)
       ▼
  DSP (Demand-Side Platform)          ← 여기서 IP 기반으로 지역/사기 판단
       │
       │  ④ Bid Response (입찰가 결정)
       ▼
  SSP → 퍼블리셔 → 유저에게 광고 노출
```

SSP가 유저 IP를 잘못 수집하면 → DSP에 잘못된 IP가 전달되고 → 전체 입찰 판단이 틀어진다. **SSP 서버에서 정확한 클라이언트 IP를 추출하는 것**이 광고 파이프라인의 첫 번째 관문이다.

---

## 1. TCP 관점: 서버가 "확실히" 아는 IP는 Peer 의 IP 뿐이다.

> 패킷이 라우터/NAT를 거칠 때 L2/L3/L4 헤더가 각각 어떻게 바뀌는지는 [[패킷이 홉을 거칠 때 헤더는 어떻게 바뀌는가]] 참고.

TCP 연결이 성립되면 서버는 커널로부터 "상대방" 주소를 받습니다.

- 이 값은 L4(전송계층) 레벨에서 신뢰할 수 있는 사실입니다. TCP 3-way handshake가 완료되어야 데이터를 주고받을 수 있으므로, 공격자가 IP를 스푸핑하면 SYN-ACK를 받을 수 없어 연결 자체가 성립되지 않습니다. (단, SYN Cookies 사용 시 ISN 예측 공격 등 예외적 시나리오가 존재하긴 합니다)
- 하지만 여기서의 "상대방"은 원래 사용자가 아니라 바로 앞에 있는 장비일 수 있습니다.

유저와 서버가 직접 연결되면 peer IP = 유저 IP라서 간단하지만, **현실에서 이런 직접 연결은 거의 없습니다.** 프로덕션 환경에는 항상 무언가가 중간에 끼어 있습니다.

### L7 프록시(ALB, Nginx 등)를 거치면?

```
유저 (203.0.113.50)
    │
    │  TCP 연결 ①: src=203.0.113.50 → dst=ALB
    ▼
AWS ALB (10.0.1.100)              ← ALB가 TCP 연결 ①을 종료(terminate)
    │
    │  TCP 연결 ②: src=10.0.1.100 → dst=10.0.2.50  ← 새로운 TCP 연결!
    ▼
내 서버 (10.0.2.50)

서버가 보는 peer IP = 10.0.1.100 ❌ ALB의 내부 IP. 유저 IP가 아님!
```

1. 유저 `203.0.113.50`이 ALB에 TCP 연결을 맺음 (연결 ①)
2. ALB는 이 연결을 받아서 **끊고**, 백엔드 서버에 **새로운** TCP 연결을 맺음 (연결 ②)
3. 서버 입장에서는 연결 ②만 보이므로, peer IP는 ALB의 IP인 `10.0.1.100`

이것이 L7 프록시(ALB, Nginx, HAProxy 등)의 기본 동작입니다. 연결을 "대리"하므로, TCP 레벨에서 원래 클라이언트 IP가 사라집니다.

> **참고: L4 로드밸런서(NLB)는 다르다** — AWS NLB는 인스턴스 타겟의 경우 기본적으로 클라이언트 IP를 보존합니다(`preserve_client_ip.enabled` 속성). IP 타겟의 경우에도 TCP/UDP 프로토콜에서는 기본 활성화됩니다. 단, TLS 프로토콜 타겟에서는 기본 비활성화이고, TLS termination을 사용하거나 뒤에 L7 프록시를 두면 다시 같은 문제가 생깁니다. 클라이언트 IP 보존이 불가능한 경우 Proxy Protocol v2를 대안으로 사용할 수 있습니다.

---

## 2. HTTP 관점: "원 IP"는 보통 **헤더**로 전달된다. (근데 스푸핑 가능)

TCP가 끊겨 다시 맺어지면, 원래 클라이언트 IP를 알려면 보통 HTTP 헤더를 씁니다.

### 대표 헤더

- `X-Forwarded-For` (XFF): 원래 Squid 캐싱 프록시에서 도입한 사실상 표준(de-facto standard) 헤더. 가장 널리 사용됩니다.
- `Forwarded` ([RFC 7239](https://datatracker.ietf.org/doc/html/rfc7239) 표준): XFF를 대체하기 위해 표준화된 헤더. `for`, `by`, `host`, `proto` 파라미터를 지원하여 더 구조화된 정보를 전달합니다. (예: `Forwarded: for=192.0.2.60;proto=http;by=203.0.113.43`)
- `X-Real-IP`: Nginx에서 주로 사용하는 비표준 헤더. 단일 IP만 담습니다.

### X-Forwarded-For 동작 원리

프록시가 하나면 XFF에 유저 IP 하나만 들어갑니다. 프록시가 여러 개일 때가 중요한데, 광고 시스템에서 흔한 CDN + ALB 구성을 봅시다:

```
유저 (203.0.113.50)
    │
    │  X-Forwarded-For: (없음)
    ▼
CloudFront (54.230.10.20)
    │
    │  X-Forwarded-For: 203.0.113.50           ← CloudFront가 유저 IP 추가
    ▼
ALB (10.0.1.100)
    │
    │  X-Forwarded-For: 203.0.113.50, 54.230.10.20  ← ALB가 CloudFront IP를 append
    ▼
내 서버 (10.0.2.50)

서버가 읽는 값:
  peer IP (RemoteAddr)  = 10.0.1.100
  X-Forwarded-For       = "203.0.113.50, 54.230.10.20"
                            ↑ 유저 IP       ↑ CloudFront IP

XFF 체인: client, proxy1, proxy2, ...
          ←── 오래된 순서 ──→ 최근 순서
```

### 보안 함정: 헤더는 "클라이언트가 마음대로 보낼 수 있다"

[MDN 문서](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For)에서도 강조하는 가장 중요한 부분입니다:

```
악의적 유저 (198.51.100.99)
    │
    │  X-Forwarded-For: 1.2.3.4             ← 공격자가 직접 넣은 가짜 IP!
    ▼
ALB (10.0.1.100)
    │
    │  X-Forwarded-For: 1.2.3.4, 198.51.100.99  ← ALB는 기존 값에 실제 peer IP를 append
    ▼
내 서버

만약 "XFF의 첫 번째 값"을 쓰면?  → 1.2.3.4 ❌ 가짜!
"오른쪽에서부터 신뢰할 수 있는 프록시를 제외"하면?  → 198.51.100.99 ✅
```

**광고에서 이게 왜 위험한가?** 공격자가 `X-Forwarded-For: 미국_IP`를 넣으면 → 서버가 미국 유저로 판단 → CPM이 높은 미국 타겟 광고를 노출 → 실제로는 CPM이 낮은 지역인데 비싼 광고를 소진 → 광고주 예산 낭비 = 사기(fraud)

그래서 원칙은:

1. "내가 신뢰하는 프록시/로드밸랜서가 붙인 구간"만 신뢰한다
2. 그 이전에 이미 들어있던 XFF 값은 그 프록시 정책에 따라 보존/추가/제거해야 한다

AWS ALB는 `routing.http.xff_header_processing.mode` 속성으로 이걸 제어합니다(`append`/`preserve`/`remove`). 기본값은 `append`로, 기존 XFF 값 뒤에 직전 홉의 IP를 추가합니다.

---

## 3. 올바르게 클라이언트 IP 추출하기: 실전 코드

### 주의: XFF 헤더가 여러 개일 수 있다

MDN 문서에 따르면, 하나의 요청에 `X-Forwarded-For` 헤더가 **여러 개** 존재할 수 있습니다. 이 경우 모든 헤더의 IP를 하나의 리스트로 합쳐서 처리해야 합니다.

```
X-Forwarded-For: 203.0.113.50, 54.230.10.20
X-Forwarded-For: 10.0.1.100

→ 하나의 리스트로 합침: [203.0.113.50, 54.230.10.20, 10.0.1.100]
```

### 원칙: "오른쪽에서부터 신뢰할 수 있는 홉을 제거"

```
X-Forwarded-For: <client?>, <proxy1?>, ..., <trusted_N>, <trusted_N-1>
                  ↑ 바로 쓰면 안 됨!          ↑ 여기서부터 왼쪽으로 벗겨냄

1. XFF를 쉼표로 split
2. 오른쪽 끝부터 시작
3. 내가 아는 신뢰할 수 있는 프록시 IP인 동안 제거
4. 처음 만나는 "신뢰할 수 없는" IP = 클라이언트 IP
```

### Go 예제

```go
// 신뢰할 수 있는 프록시 대역 (예: AWS 내부 + CloudFront)
var trustedProxies = []net.IPNet{
    parseCIDR("10.0.0.0/8"),       // AWS VPC 내부
    parseCIDR("172.16.0.0/12"),    // Private
    parseCIDR("192.168.0.0/16"),   // Private
    parseCIDR("54.230.0.0/16"),    // CloudFront (예시, 실제로는 https://ip-ranges.amazonaws.com/ip-ranges.json 참조)
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
    //   예: ["1.2.3.4", "203.0.113.50", "54.230.10.20", "10.0.1.100"]
    //         가짜       진짜 유저        CloudFront(✓)   ALB(✓)
    //   → 오른쪽부터 trusted 제거 → 203.0.113.50이 클라이언트!
    for i := len(parts) - 1; i >= 0; i-- {
        if !isTrustedProxy(parts[i]) {
            return parts[i]
        }
    }

    host, _, _ := net.SplitHostPort(r.RemoteAddr)
    return host
}
```

> **프레임워크 내장 기능**: Express.js는 `app.set('trust proxy', '10.0.0.0/8, 54.230.0.0/16')` 처럼 CIDR 목록을 설정하면, 내부적으로 [proxy-addr](https://www.npmjs.com/package/proxy-addr) 패키지를 사용하여 오른쪽에서부터 신뢰 프록시를 제거하는 동일한 로직을 적용합니다. `req.ip`가 최종 클라이언트 IP를 반환합니다. Nginx는 `proxy_set_header X-Real-IP $remote_addr`와 `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for`를 조합하여 사용하고, 백엔드에서는 `ngx_http_realip_module`의 `set_real_ip_from`, `real_ip_header` 디렉티브로 신뢰 프록시를 지정할 수 있습니다.

---

## 4. 광고 업계 특수 상황: IP만으로는 부족한 경우들

### Carrier-Grade NAT (CGNAT)

```
유저 A (내부: 100.64.0.1)  ─┐
                              ├── 통신사 NAT ── 공인 IP: 203.0.113.1
유저 B (내부: 100.64.0.2)  ─┘

유저 A와 B가 같은 IP(203.0.113.1)로 보임!
```

모바일 통신사는 IPv4 주소 고갈 문제를 해결하기 위해 CGNAT를 사용합니다. [RFC 6598](https://datatracker.ietf.org/doc/html/rfc6598)에서 정의한 `100.64.0.0/10` 대역(Shared Address Space)을 ISP 내부에서 사용하고, 이를 소수의 공인 IP로 변환합니다. 수천 명의 유저가 같은 공인 IP를 공유할 수 있어서 IP 기반 프리퀀시 캡핑/유저 식별이 사실상 불가능합니다. 광고 업계에서는 IP + User-Agent + 기타 시그널을 조합하거나, 디바이스 ID(ADID/IDFA)를 병행합니다.

### VPN / 프록시 사용자

한국 유저가 미국 VPN을 타면 서버는 미국 IP를 보게 됩니다. → 미국 타겟 광고가 잘못 노출됨. VPN 탐지를 위해 IP 평판 데이터베이스(MaxMind, IPQualityScore 등)를 활용하는 경우가 많습니다.

### IPv6

코드에서 IPv4만 가정하면 안 됩니다:

```go
// ❌ IPv4만 고려
ip := strings.Split(remoteAddr, ":")[0]  // IPv6 주소에서 망가짐

// ✅ net.SplitHostPort 사용
host, _, _ := net.SplitHostPort(remoteAddr)
// "203.0.113.50:8080"    → "203.0.113.50"
// "[2001:db8::1]:8080"   → "2001:db8::1"
```

---

## 체크리스트: 새 광고 서버를 세팅할 때

```
□ 내 서버 앞에 어떤 프록시/로드밸런서가 있는지 인프라 팀에 확인
□ 각 프록시가 XFF를 어떻게 처리하는지 확인 (append? overwrite? 무시?)
□ 신뢰할 수 있는 프록시의 IP 대역(CIDR) 목록 확보
□ "오른쪽에서 벗기기" 로직으로 클라이언트 IP 추출 구현
□ IPv6 주소도 올바르게 파싱되는지 테스트
□ XFF 스푸핑 테스트 (가짜 XFF를 넣어보고 올바른 IP가 나오는지)
□ IP 기반 Geo DB(MaxMind GeoIP2 등)와 연동 테스트
□ CGNAT/VPN 상황에서의 fallback 전략 수립 (디바이스 ID 병행 등)
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
                │       └── 오른쪽부터 trusted proxy 제거 → ✅ 올바른 IP
                │
                └── 그래도 부족한 경우
                        ├── CGNAT: 여러 유저가 같은 IP
                        ├── VPN: 유저 위치 불일치
                        └── → IP + 다른 시그널 조합 필요
```

---

## 참고자료

- [MDN - X-Forwarded-For](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For) — XFF 헤더의 동작, 파싱, 보안 주의사항, IP 선택 방법에 대한 가장 체계적인 레퍼런스
- [RFC 7239 - Forwarded HTTP Extension](https://datatracker.ietf.org/doc/html/rfc7239) — X-Forwarded-For를 대체하기 위한 표준 Forwarded 헤더 명세
- [RFC 6598 - IANA-Reserved IPv4 Prefix for Shared Address Space](https://datatracker.ietf.org/doc/html/rfc6598) — CGNAT에서 사용하는 100.64.0.0/10 대역 정의
- [AWS - HTTP headers and Application Load Balancers](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/x-forwarded-headers.html) — ALB의 XFF 헤더 처리 모드(append/preserve/remove) 공식 문서
- [AWS - Network Load Balancer Target Groups](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-target-groups.html) — NLB의 클라이언트 IP 보존 동작 및 Proxy Protocol 설정
- [AWS - CloudFront IP Ranges](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/LocationsOfEdgeServers.html) — CloudFront 엣지 서버 IP 대역 확인 방법 (ip-ranges.json)
- [IAB - OpenRTB 2.6 Specification](https://github.com/InteractiveAdvertisingBureau/openrtb2.x/blob/main/2.6.md) — OpenRTB 입찰 요청의 device.ip 필드 명세
- [Express.js - Behind Proxies](https://expressjs.com/en/guide/behind-proxies.html) — Express의 trust proxy 설정과 req.ip 동작
- [Nginx - ngx_http_realip_module](https://nginx.org/en/docs/http/ngx_http_realip_module.html) — Nginx에서 실제 클라이언트 IP를 추출하기 위한 모듈
- [HTTP Toolkit - What is X-Forwarded-For and when can you trust it?](https://httptoolkit.com/blog/what-is-x-forwarded-for/) — XFF 신뢰 문제와 오른쪽에서부터 벗기기 접근법에 대한 실용적 해설

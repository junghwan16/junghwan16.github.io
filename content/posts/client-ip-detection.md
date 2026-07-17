---
title: "프록시 뒤에서 클라이언트 IP는 어디로 갔을까"
url: "/backend/network/2026/02/07/client-ip-detection/"
date: 2026-02-07 13:00:00 +0900
categories: [backend, network]
---

서버에서 `RemoteAddr`를 찍었더니 전부 ALB나 Nginx 주소인 경우가 있다. 이상한 일이 아니다. L7 프록시는 클라이언트 TCP 연결을 종료하고, 백엔드 서버에 새 TCP 연결을 만든다. 서버가 커널에서 받는 peer IP는 원래 사용자 IP가 아니라 바로 앞 프록시 IP다.

그래서 클라이언트 IP는 두 층으로 봐야 한다.

| 관점 | 값 | 신뢰도 |
|---|---|---|
| TCP peer IP | 내 서버에 직접 연결한 상대 | 커널이 준 값이라 신뢰 가능 |
| HTTP 원 IP | 프록시가 헤더로 전달한 원 사용자 | 신뢰 프록시가 붙인 구간만 신뢰 가능 |

## `RemoteAddr`는 바로 앞 홉이다

L7 프록시가 있으면 연결은 두 개가 된다.

```text
user -> ALB      : user가 ALB와 맺은 TCP 연결
ALB  -> app      : ALB가 app과 새로 맺은 TCP 연결
```

앱 서버가 보는 `RemoteAddr`는 ALB의 주소다. 사용자의 원래 IP가 아니다.

L4 로드밸런서는 구성에 따라 클라이언트 IP를 보존할 수 있다. 하지만 TLS termination이나 L7 프록시가 들어오면 다시 같은 문제가 생긴다. 이때는 `X-Forwarded-For`, `Forwarded`, Proxy Protocol 같은 별도 전달 수단이 필요하다.

## `X-Forwarded-For`는 조작 가능하다

가장 흔한 헤더는 `X-Forwarded-For`다. 프록시는 기존 값 뒤에 자신이 받은 peer IP를 append한다.

```text
X-Forwarded-For: 203.0.113.50, 54.230.10.20, 10.0.1.100
                 client        proxy1        proxy2
```

문제는 클라이언트가 처음부터 이 헤더를 넣을 수 있다는 점이다.

```text
악의적 클라이언트 요청:
X-Forwarded-For: 1.2.3.4

ALB가 append한 뒤:
X-Forwarded-For: 1.2.3.4, 198.51.100.99
```

첫 번째 값을 그대로 믿으면 공격자가 쓴 `1.2.3.4`를 클라이언트 IP로 받아들이게 된다.

## 오른쪽에서 trusted proxy를 벗긴다

안전한 규칙은 오른쪽에서 왼쪽으로 읽는 것이다.

1. `RemoteAddr`가 신뢰할 수 있는 프록시인지 확인한다.
2. `X-Forwarded-For`를 쉼표로 나눈다.
3. 오른쪽 끝에서부터 trusted proxy CIDR에 속하는 IP를 제거한다.
4. 처음 만나는 신뢰할 수 없는 IP를 클라이언트 IP로 본다.

```go
func ClientIP(r *http.Request, trusted []netip.Prefix) (netip.Addr, bool) {
    remote, _, err := net.SplitHostPort(r.RemoteAddr)
    if err != nil {
        return netip.Addr{}, false
    }

    peer, err := netip.ParseAddr(remote)
    if err != nil {
        return netip.Addr{}, false
    }

    if !isTrusted(peer, trusted) {
        return peer, true
    }

    parts := strings.Split(r.Header.Get("X-Forwarded-For"), ",")
    for i := len(parts) - 1; i >= 0; i-- {
        ip, err := netip.ParseAddr(strings.TrimSpace(parts[i]))
        if err != nil {
            continue
        }
        if !isTrusted(ip, trusted) {
            return ip, true
        }
    }

    return peer, true
}
```

trusted CIDR에는 내 인프라가 제어하는 프록시만 넣어야 한다. 사설 대역 전체를 무조건 신뢰하거나, CloudFront/ALB 대역을 갱신하지 않는 식의 설정은 시간이 지나면 틀어진다.

## IP만으로는 부족하다

클라이언트 IP는 식별자가 아니라 네트워크 단서다.

- 모바일 통신망의 CGNAT에서는 여러 사용자가 같은 공인 IP를 공유한다.
- VPN이나 회사 프록시를 쓰면 위치와 사용자를 착각할 수 있다.
- IPv6 주소는 단순히 `:`로 split하면 깨진다. `net.SplitHostPort`나 `netip`를 써야 한다.
- 보안 판단에는 IP만 쓰지 말고 계정, 세션, 디바이스, 속도 제한 키를 함께 봐야 한다.

## 체크리스트

- 서버 앞의 프록시 체인을 문서화한다.
- 각 프록시가 XFF를 append, preserve, remove 중 어떻게 처리하는지 확인한다.
- trusted proxy CIDR을 코드나 설정으로 명시한다.
- XFF 첫 번째 값을 그대로 쓰지 않는다.
- IPv6와 여러 개의 XFF 헤더를 테스트한다.
- IP 기반 차단이나 rate limit은 우회 가능성을 전제로 둔다.

프록시 뒤에서 클라이언트 IP를 찾는 문제는 "어느 헤더를 읽을까"가 아니다. 내가 신뢰할 수 있는 홉이 어디까지인지 정하고, 그 경계 밖의 값은 입력값으로만 취급하는 문제다.

---
title: "패킷이 홉을 거칠 때 헤더는 어떻게 바뀌는가"
url: "/network/2026/02/07/packet-header-changes/"
date: 2026-02-07 12:00:00 +0900
categories: [network]
---

프록시 뒤에서 클라이언트 IP가 사라지는 이유를 이해하려면, 패킷이 홉을 지날 때 어떤 헤더가 바뀌는지 보면 된다. 핵심은 L2는 매 홉 바뀌고, L3/L4는 NAT이나 프록시가 개입할 때만 바뀐다는 점이다.

## 기본 구조

```text
Ethernet frame
  IP packet
    TCP segment
      HTTP payload
```

각 레이어가 보는 대상이 다르다.

| 레이어 | 주소 | 의미 |
|---|---|---|
| L2 | MAC | 다음 홉까지 전달 |
| L3 | IP | 최종 출발지와 최종 목적지 |
| L4 | Port | 프로세스 간 연결 |
| L7 | HTTP header/body | 애플리케이션 의미 |

## 일반 라우팅: L2만 바뀐다

NAT이 없고 라우터만 지나는 경우, IP와 port는 유지된다. 각 홉에서 다음 장비로 보내기 위해 MAC만 새로 붙는다.

```text
PC -> Router A -> Router B -> Server

L2 MAC: hop마다 변경
L3 IP : client -> server 유지
L4 port: client_port -> 443 유지
```

## SNAT: 출발지가 바뀐다

집 공유기나 NAT Gateway를 지나 인터넷으로 나갈 때는 source IP와 source port가 바뀐다.

```text
내부:
  192.168.0.10:52431 -> 93.184.216.34:443

외부:
  203.0.113.1:30001 -> 93.184.216.34:443
```

NAT 장비는 매핑 테이블을 갖고 있다.

| 내부 | 외부 |
|---|---|
| `192.168.0.10:52431` | `203.0.113.1:30001` |

서버 입장에서는 `192.168.0.10`을 볼 수 없다. `203.0.113.1`에서 요청이 온 것으로 보인다.

## DNAT: 목적지가 바뀐다

로드밸런서나 포트포워딩에서는 destination IP와 port가 바뀐다.

```text
client -> LB VIP:
  198.51.100.5:48000 -> 203.0.113.10:443

LB -> backend:
  198.51.100.5:48000 -> 10.0.1.50:8080
```

이 경우 source IP가 유지되면 백엔드는 클라이언트 IP를 직접 볼 수 있다. L4 로드밸런서에서 클라이언트 IP 보존이 가능한 이유다. 단, 응답 경로가 다시 LB를 통과하도록 설계되어야 한다.

## L7 프록시: 새 연결을 만든다

ALB, Nginx, Envoy 같은 L7 프록시는 클라이언트 TCP 연결을 종료하고 백엔드에 새 TCP 연결을 만든다.

```text
connection A:
  client -> proxy
  198.51.100.5:48000 -> 203.0.113.10:443

connection B:
  proxy -> app
  10.0.1.100:55000 -> 10.0.2.50:8080
```

백엔드가 보는 peer IP는 proxy IP다. 원래 클라이언트 IP를 전달하려면 `X-Forwarded-For`나 `Forwarded` 같은 L7 헤더가 필요하다.

## 비교표

| 상황 | L2 MAC | L3 src | L3 dst | L4 port | 앱 서버가 보는 클라이언트 |
|---|---|---|---|---|---|
| 일반 라우팅 | 매 홉 변경 | 유지 | 유지 | 유지 | 원 클라이언트 |
| SNAT | 매 홉 변경 | 변경 | 유지 | src 변경 | NAT 장비 |
| DNAT | 매 홉 변경 | 유지 | 변경 | dst 변경 | 원 클라이언트 가능 |
| L7 프록시 | 새 연결 | 프록시 IP | 백엔드 IP | 새 포트 | 프록시 |

`RemoteAddr`가 왜 ALB 주소인지, NLB에서는 왜 원 IP가 보일 수 있는지, XFF를 왜 신뢰 경계와 함께 봐야 하는지가 여기서 나온다.

## 참고자료

- [RFC 791 - Internet Protocol](https://datatracker.ietf.org/doc/html/rfc791)
- [RFC 2663 - NAT Terminology](https://datatracker.ietf.org/doc/html/rfc2663)
- [AWS ALB X-Forwarded headers](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/x-forwarded-headers.html)

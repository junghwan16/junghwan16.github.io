---
title: "패킷이 홉을 거칠 때 헤더는 어떻게 바뀌는가"
url: "/network/2026/02/07/packet-header-changes/"
date: 2026-02-07 12:00:00 +0900
categories: [network]
---

> 관련 문서: [[클라이언트의 IP를 알아내는 방법]]

네트워크 패킷이 라우터/스위치를 거치면서 "어떤 헤더는 바뀌고, 어떤 헤더는 안 바뀌는가"를 이해하면, 왜 프록시 뒤에서 클라이언트 IP가 사라지는지 자연스럽게 이해할 수 있다.

---

## 먼저: 패킷의 계층 구조

네트워크 패킷은 러시아 인형(마트료시카)처럼 겹겹이 감싸져 있다:

```
┌─────────────────────────────────────────────────────┐
│ L2 Ethernet Frame                                   │
│  src MAC → dst MAC                                  │
│ ┌─────────────────────────────────────────────────┐ │
│ │ L3 IP Packet                                    │ │
│ │  src IP → dst IP                                │ │
│ │ ┌─────────────────────────────────────────────┐ │ │
│ │ │ L4 TCP Segment                              │ │ │
│ │ │  src Port → dst Port                        │ │ │
│ │ │ ┌─────────────────────────────────────────┐ │ │ │
│ │ │ │ L7 Payload (HTTP 등)                    │ │ │ │
│ │ │ └─────────────────────────────────────────┘ │ │ │
│ │ └─────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

핵심 질문: **각 홉에서 어떤 레이어의 헤더가 바뀌는가?**

---

## 1. 일반 라우팅 (NAT 없음): L2만 바뀌고, L3/L4는 그대로

가장 기본적인 경우부터 보자. NAT가 없는 순수한 라우팅이다.

### 시나리오: PC → 라우터 A → 라우터 B → 서버

```
PC (10.1.1.10)          라우터A              라우터B          서버 (10.3.3.30)
MAC: aa:aa             MAC: bb:bb / cc:cc   MAC: dd:dd / ee:ee   MAC: ff:ff
       │                     │                    │                   │
       └────── 홉 1 ─────────┘                    │                   │
                              └────── 홉 2 ────────┘                   │
                                                   └────── 홉 3 ───────┘
```

> 라우터는 인터페이스(포트)가 여러 개이므로 MAC이 여러 개다. `bb:bb`는 PC 쪽 인터페이스, `cc:cc`는 라우터B 쪽 인터페이스.

#### 홉 1: PC → 라우터 A

```
L2:  src MAC = aa:aa (PC)        dst MAC = bb:bb (라우터A 입구)
L3:  src IP  = 10.1.1.10 (PC)   dst IP  = 10.3.3.30 (서버)      ← 안 바뀜
L4:  src Port = 52431            dst Port = 80                    ← 안 바뀜
```

PC는 "서버 `10.3.3.30`에 보내고 싶다"고 하지만, 직접 보낼 수 없으니 게이트웨이(라우터A)의 MAC 주소로 프레임을 보낸다. **L3 dst IP는 최종 목적지(서버)이고, L2 dst MAC은 다음 홉(라우터A)이다.**

#### 홉 2: 라우터 A → 라우터 B

```
L2:  src MAC = cc:cc (라우터A 출구)   dst MAC = dd:dd (라우터B 입구)   ← L2 바뀜!
L3:  src IP  = 10.1.1.10             dst IP  = 10.3.3.30             ← 그대로
L4:  src Port = 52431                dst Port = 80                    ← 그대로
```

라우터A는 L2 프레임을 벗기고(decapsulate), 라우팅 테이블을 보고 다음 홉을 결정한 뒤, 새 L2 프레임으로 다시 감싼다(encapsulate). **L3/L4는 건드리지 않는다.**

#### 홉 3: 라우터 B → 서버

```
L2:  src MAC = ee:ee (라우터B 출구)   dst MAC = ff:ff (서버)           ← L2 바뀜!
L3:  src IP  = 10.1.1.10             dst IP  = 10.3.3.30             ← 그대로
L4:  src Port = 52431                dst Port = 80                    ← 그대로
```

### 정리: 일반 라우팅에서 각 레이어의 변화

```
         홉 1           홉 2           홉 3
L2 MAC:  aa→bb          cc→dd          ee→ff         ← 매 홉마다 바뀜
L3 IP:   10.1.1.10 → 10.3.3.30                       ← 출발지~도착지 불변
L4 Port: 52431 → 80                                   ← 출발지~도착지 불변
```

> **왜 L2만 바뀌나?** L2(이더넷)는 "같은 네트워크 안에서 다음 장비까지" 프레임을 전달하는 역할이다. 네트워크가 바뀌면(라우터를 넘으면) L2 프레임을 벗기고 새로 만든다. 반면 L3 IP는 "최종 출발지 → 최종 목적지"를 나타내므로 중간에 바뀌지 않는다.

---

## 2. SNAT (Source NAT): L3 src IP + L4 src Port가 바뀐다

집에서 공유기를 쓰거나, 회사에서 NAT 게이트웨이를 쓸 때 일어나는 일이다.

### 시나리오: 집 PC → 공유기(NAT) → 인터넷 → 서버

```
PC (192.168.0.10)     공유기 (NAT)           서버 (93.184.216.34)
사설 IP               WAN: 203.0.113.1       공인 IP
                      LAN: 192.168.0.1
```

#### 홉 1: PC → 공유기 (NAT 전)

```
L2:  src MAC = (PC)              dst MAC = (공유기 LAN)
L3:  src IP  = 192.168.0.10     dst IP  = 93.184.216.34
L4:  src Port = 52431            dst Port = 80
```

#### 홉 2: 공유기 → 인터넷 (NAT 후)

```
L2:  src MAC = (공유기 WAN)      dst MAC = (ISP 라우터)            ← L2 바뀜 (당연)
L3:  src IP  = 203.0.113.1      dst IP  = 93.184.216.34          ← 🔴 src IP 바뀜!
L4:  src Port = 30001            dst Port = 80                    ← 🔴 src Port 바뀜!
```

**무슨 일이 일어났나?**

```
NAT 테이블 (공유기 내부):
┌──────────────────────────────┬─────────────────────────────┐
│ 내부 (변환 전)                │ 외부 (변환 후)                │
├──────────────────────────────┼─────────────────────────────┤
│ 192.168.0.10:52431           │ 203.0.113.1:30001           │
└──────────────────────────────┴─────────────────────────────┘

공유기가 하는 일:
1. 나가는 패킷: src IP를 사설→공인으로, src Port를 새 포트로 변환
2. NAT 테이블에 매핑 기록
3. 돌아오는 패킷: dst 203.0.113.1:30001 → dst 192.168.0.10:52431로 역변환
```

서버 입장에서는 `203.0.113.1:30001`에서 요청이 온 것으로 보인다. 사설 IP `192.168.0.10`은 보이지 않는다.

#### 응답이 돌아올 때 (역방향)

```
서버 → 공유기:
  L3: src=93.184.216.34  dst=203.0.113.1
  L4: src=80             dst=30001

공유기 → PC (NAT 역변환):
  L3: src=93.184.216.34  dst=192.168.0.10     ← 🔴 dst IP 복원
  L4: src=80             dst=52431             ← 🔴 dst Port 복원
```

### 정리: SNAT에서 각 레이어의 변화

```
         NAT 전 (내부)            NAT 후 (외부)
L2 MAC:  바뀜 (매 홉마다)         바뀜 (매 홉마다)
L3 src:  192.168.0.10       →    203.0.113.1          ← 🔴 변환됨
L3 dst:  93.184.216.34           93.184.216.34         ← 그대로
L4 src:  52431              →    30001                 ← 🔴 변환됨
L4 dst:  80                      80                    ← 그대로
```

---

## 3. DNAT (Destination NAT): L3 dst IP + L4 dst Port가 바뀐다

서버 앞에 로드밸런서를 두거나, 포트포워딩을 할 때 일어나는 일이다.

### 시나리오: 클라이언트 → LB (DNAT) → 백엔드 서버

```
클라이언트 (198.51.100.5)     LB (VIP: 203.0.113.10)     백엔드 (10.0.1.50)
```

#### 클라이언트 → LB

```
L3:  src IP  = 198.51.100.5     dst IP  = 203.0.113.10 (VIP)
L4:  src Port = 48000            dst Port = 443
```

#### LB → 백엔드 (DNAT 후)

```
L3:  src IP  = 198.51.100.5     dst IP  = 10.0.1.50          ← 🔵 dst IP 바뀜!
L4:  src Port = 48000            dst Port = 8080               ← 🔵 dst Port 바뀜!
```

**src IP가 그대로이므로**, 백엔드 서버는 클라이언트의 진짜 IP를 볼 수 있다. 이것이 L4 로드밸런서(AWS NLB 등)에서 "클라이언트 IP 보존"이 가능한 이유이다.

> 단, 응답 패킷이 LB를 거치지 않고 직접 클라이언트로 가면 문제가 생긴다 (src=10.0.1.50인데 클라이언트는 203.0.113.10에서 응답을 기대). 이를 해결하기 위해 DSR(Direct Server Return) 또는 LB를 경유하는 리턴 경로 설정이 필요하다.

---

## 4. Full NAT (SNAT + DNAT): L7 프록시가 하는 일

ALB, Nginx 리버스 프록시 등 L7 프록시는 TCP 연결 자체를 끊고 새로 맺는다. 이건 NAT이라기보다 **완전히 새로운 연결**이다.

### 시나리오: 클라이언트 → ALB → 백엔드

```
=== 연결 A: 클라이언트 → ALB ===
L3:  src = 198.51.100.5      dst = 203.0.113.10 (ALB)
L4:  src = 48000              dst = 443

=== 연결 B: ALB → 백엔드 (완전히 별개의 TCP 연결) ===
L3:  src = 10.0.1.100 (ALB)  dst = 10.0.2.50 (백엔드)    ← 🔴 src, dst 둘 다 바뀜
L4:  src = 55000 (ALB)        dst = 8080                   ← 🔴 src, dst 둘 다 바뀜
```

연결 A와 연결 B는 **아무 관계가 없는 별개의 TCP 세션**이다. 백엔드가 보는 건 연결 B뿐이므로:
- src IP = ALB의 IP → 클라이언트 IP를 알 수 없음
- 그래서 `X-Forwarded-For` 같은 **L7 헤더**로 원래 IP를 전달해야 함

---

## 전체 비교 요약

```
                    │ L2 (MAC)  │ L3 src IP  │ L3 dst IP  │ L4 Port  │ 클라이언트 IP
────────────────────┼───────────┼────────────┼────────────┼──────────┼──────────────
일반 라우팅          │ 매 홉 변경 │ 불변       │ 불변       │ 불변     │ 보임 ✅
SNAT (공유기)        │ 매 홉 변경 │ 🔴 변환    │ 불변       │ 🔴 변환  │ 안 보임 ❌
DNAT (L4 LB)        │ 매 홉 변경 │ 불변       │ 🔵 변환    │ 🔵 변환  │ 보임 ✅
Full NAT (L7 프록시) │ 매 홉 변경 │ 🔴 변환    │ 🔵 변환    │ 전부 변환 │ 안 보임 ❌
```

이 표가 [[클라이언트의 IP를 알아내는 방법]]에서 다룬 내용의 근본적인 이유이다:
- **DNAT만 하는 L4 LB** → src IP 보존 → `RemoteAddr`로 클라이언트 IP를 알 수 있음
- **Full NAT인 L7 프록시** → src IP 소실 → `X-Forwarded-For` 등 L7 헤더가 필요함

---

## 참고자료

- [RFC 791 - Internet Protocol (IPv4)](https://datatracker.ietf.org/doc/html/rfc791) — IP 패킷 헤더 구조와 라우팅 원리의 원본 명세
- [RFC 2663 - IP Network Address Translator (NAT) Terminology and Considerations](https://datatracker.ietf.org/doc/html/rfc2663) — SNAT, DNAT 등 NAT 유형에 대한 IETF 공식 용어 정의
- [RFC 6269 - Issues with IP Address Sharing](https://datatracker.ietf.org/doc/html/rfc6269) — NAT/CGNAT 환경에서의 IP 공유로 인한 보안 이슈
- [AWS - Network Load Balancer Target Groups](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-target-groups.html) — NLB(L4 LB)의 DNAT 기반 클라이언트 IP 보존 동작
- [AWS - HTTP headers and Application Load Balancers](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/x-forwarded-headers.html) — ALB(L7 프록시)가 Full NAT 후 XFF 헤더로 원래 IP를 전달하는 방식
- [Cloudflare - What is a MAC address?](https://www.cloudflare.com/learning/network-layer/what-is-a-mac-address/) — L2 MAC 주소가 매 홉마다 바뀌는 이유

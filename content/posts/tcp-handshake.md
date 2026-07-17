---
title: "TCP는 왜 세 번 연결하고 네 번 끊을까"
url: "/network/2026/03/22/tcp-handshake/"
date: 2026-03-22 12:00:00 +0900
categories: [network]
---

`SYN -> SYN-ACK -> ACK`는 외우기 쉽다. 중요한 건 왜 두 번이 아니라 세 번인지, 종료할 때는 왜 네 번인지다. 답은 TCP가 양방향 연결이고, 각 방향의 데이터 흐름을 독립적으로 확인하기 때문이다.

## 연결은 세 번

```text
Client                         Server
  |--- SYN seq=100 ------------>|
  |<-- SYN-ACK seq=300 ack=101 -|
  |--- ACK ack=301 ------------>|
```

첫 SYN은 클라이언트가 보낸다. 서버는 SYN을 받았다고 ACK하면서, 동시에 자기 SYN을 보낸다. 마지막 ACK로 클라이언트는 서버의 SYN도 받았다고 확인한다.

두 번에서 끝내면 서버는 자신의 SYN-ACK가 클라이언트에게 도착했는지 모른다. 세 번째 ACK가 있어야 양방향 통신 가능성이 확인된다.

## sequence number도 교환한다

handshake는 생존 확인만 하는 절차가 아니다. 양쪽이 각각 초기 sequence number를 고른다.

```text
Client -> Server 방향: client seq 기준
Server -> Client 방향: server seq 기준
```

ACK는 "다음에 기대하는 sequence number"다. 이 번호 덕분에 TCP는 순서, 중복, 유실을 다룬다.

```text
seq=101 전송
ack=102 응답
seq=102 전송 유실
timeout 후 seq=102 재전송
```

TCP의 신뢰성은 sequence number, ACK, 재전송 위에 있다.

## 연결 비용이 있다

3-way handshake는 최소 1 RTT가 필요하다. TLS까지 붙으면 비용은 더 커진다. 그래서 HTTP keep-alive, connection pool, database pool이 중요하다. 매 요청마다 새 TCP 연결을 만들면 handshake 비용을 계속 낸다.

SYN flood도 여기서 나온다. 공격자가 SYN만 보내고 마지막 ACK를 보내지 않으면 서버는 half-open 연결을 기다리며 자원을 쓴다. SYN cookie는 서버가 상태를 덜 저장하도록 만든 대응이다.

## 종료는 네 번

```text
Client                         Server
  |--- FIN -------------------->|
  |<-- ACK ---------------------|
  |<-- FIN ---------------------|
  |--- ACK -------------------->|
```

연결 수립 때는 서버가 `SYN`과 `ACK`를 한 패킷으로 합칠 수 있었다. 종료 때는 보통 합칠 수 없다. 클라이언트가 "나는 더 보낼 데이터가 없다"고 했다고 해서 서버도 바로 끝난 것은 아니기 때문이다.

서버에 아직 보낼 응답이 남아 있으면 먼저 ACK만 보내고, 데이터를 다 보낸 뒤 FIN을 보낸다. 이를 half-close라고 볼 수 있다. 한쪽 방향은 닫혔지만 반대 방향은 잠시 더 열려 있다.

## TIME_WAIT

마지막 ACK를 보낸 쪽은 바로 사라지지 않고 TIME_WAIT에 머문다.

이유는 두 가지다.

- 마지막 ACK가 유실되면 상대가 FIN을 재전송할 수 있다.
- 이전 연결의 지연 패킷이 같은 4-tuple의 새 연결에 섞이는 것을 막아야 한다.

TIME_WAIT이 많아지면 포트 고갈처럼 보일 수 있지만, 이 상태 자체는 TCP가 안전하게 연결을 닫기 위한 장치다.

TCP는 느린 프로토콜이 아니라, 신뢰성을 위해 상태를 갖는 프로토콜이다. handshake와 종료 절차는 그 상태를 양쪽이 같은 그림으로 맞추기 위한 비용이다.

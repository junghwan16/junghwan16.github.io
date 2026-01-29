---
layout: single
title: "Kafka vs RabbitMQ 핵심 개념 정리"
date: 2026-01-30 10:00:00 +0900
categories: [backend, messaging]
---

메시지 브로커 선택은 시스템 설계에서 중요한 결정이다. Kafka와 RabbitMQ의 차이를 개념부터 실전 패턴까지 정리했다.

## 먼저 생각해볼 것

> - 메시지를 한 번 소비하면 끝인가, 여러 시스템이 같은 메시지를 각자 필요로 하는가?
> - 처리 실패 시 재시도는 어떻게 하는가? 순서가 중요한가?
> - 과거 데이터를 다시 처리해야 할 일이 있는가?
> - 초당 처리량은 어느 정도인가?

---

## 메시지 브로커란?

**애플리케이션, 시스템, 서비스 간의 통신을 중개하는 미들웨어 소프트웨어**다.

- **역할**: 발신자와 수신자가 서로의 위치나 상태를 알 필요 없이 데이터를 주고 받을 수 있게 해준다 (디커플링)
- **기능**: 메시지의 유효성 검사, 라우팅, 저장(버퍼링), 프로토콜 변환
- **비유**: 우체국. 편지를 보내는 사람(producer)은 받는 사람(consumer)이 집에 있는지 신경 쓰지 않고 우체통(broker)에 넣기만 하면 된다

---

## 아키텍처 차이

### 메시지 소비 방식

| | RabbitMQ | Kafka |
|---|---|---|
| 메시지 소비 | Consumer가 가져가면 **삭제됨** | Consumer가 읽어도 **유지됨** |
| 비유 | 택배 수령 (가져가면 끝) | 게시판 열람 (누가 봐도 글은 그대로) |
| 저장 방식 | 메모리 중심 | 디스크에 로그처럼 저장 |
| 전달 모델 | **Push** — 브로커가 Consumer에게 밀어줌 | **Pull** — Consumer가 브로커에서 당겨감 |

### Push vs Pull

```
┌─────────────────────────────────────────────────────────────────┐
│                     RabbitMQ (Push)                             │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐              │
│  │ Producer │ ──── │  Broker  │ ════>│ Consumer │              │
│  └──────────┘      └──────────┘      └──────────┘              │
│                         │                  │                    │
│                    브로커가 주도     "받아라!" (수동적)          │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                       Kafka (Pull)                              │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐              │
│  │ Producer │ ──── │  Broker  │ <════│ Consumer │              │
│  └──────────┘      └──────────┘      └──────────┘              │
│                         │                  │                    │
│                    로그만 저장       "줘!" (능동적)              │
└─────────────────────────────────────────────────────────────────┘
```

**RabbitMQ (Smart Broker, Dumb Consumer)**
- 브로커가 큐에 메시지가 들어오자마자 즉시 밀어 넣는다
- 지연 시간 최소화. `prefetch_count`로 흐름 제어

**Kafka (Dumb Broker, Smart Consumer)**
- 컨슈머가 자신의 처리 능력에 맞춰 속도 조절
- 장애 발생해도 브로커에 데이터가 그대로 있어 나중에 다시 가져올 수 있음

---

## RabbitMQ: Exchange와 Queue

**복잡한 라우팅**을 구현하는 핵심 요소들이다.

```
Producer -> [Exchange] --binding--> [에러 로그 큐] --> 알림 서비스
                       --binding--> [전체 로그 큐] --> 아카이빙 서비스
```

- **Exchange**: 메시지를 어떤 큐로 보낼지 결정하는 라우팅 로직. 저장하지 않음
- **Queue**: 메시지가 소비되기 전까지 실제로 저장되는 버퍼
- **Binding**: Exchange와 Queue를 연결하는 규칙 (Routing Key 기반)

### Exchange 타입

| Exchange 타입 | 라우팅 방식 |
|---|---|
| **Direct** | routing key가 정확히 일치하는 큐로 전달 |
| **Topic** | 와일드카드 패턴 매칭 (`*`: 한 단어, `#`: 0개 이상) |
| **Fanout** | 바인딩된 모든 큐에 브로드캐스트 |
| **Headers** | 메시지 header 속성 기반 매칭 |

### AMQP 프로토콜

RabbitMQ는 **AMQP(Advanced Message Queuing Protocol)** 0.91을 사용한다. ISO/IEC 국제 표준으로, 메시지 전송 형식뿐 아니라 브로커 내부 동작 방식(Exchange, Queue, Binding)까지 정의한다.

---

## Kafka: Consumer Group과 Partition

### Consumer Group

같은 클릭 이벤트를 여러 시스템이 필요로 하는 상황:

```
광고 클릭 이벤트 발생 -> 여러 시스템이 필요로 함:
- 정산 시스템: 광고주에게 비용 청구
- 분석 시스템: 클릭률(CTR) 집계
- 실시간 대시보드: 광고주가 보는 현황판
```

정산 서버가 3대인데 같은 클릭 이벤트를 3대 모두 처리하면 100원짜리 클릭이 300원으로 과청구된다.

```
클릭 이벤트 -> [ Kafka Topic: ad-clicks ]
                    |
        +-----------+-----------+
        v           v           v
    +-----------------------------+
    |  Consumer Group: "정산"      |  <- 3대가 이벤트를 나눠서 처리
    |  서버A  서버B  서버C         |     (한 이벤트는 딱 한 대만)
    +-----------------------------+

    +-----------------------------+
    |  Consumer Group: "분석"      |  <- 별도 그룹이라 같은 이벤트를 또 받음
    +-----------------------------+
```

**핵심 규칙**
- **같은 Consumer Group 내에서는** -> 이벤트를 나눠 가짐 (중복 처리 방지)
- **다른 Consumer Group끼리는** -> 같은 이벤트를 각자 받음

### Offset

메시지가 순서대로 쌓이므로, 각 메시지에 번호(offset)가 붙는다: 0, 1, 2, 3...

```
"정산 그룹은 offset 1542까지 읽었다"
```

Kafka는 Consumer의 현재 위치를 `__consumer_offsets` 내부 토픽에 저장한다. 메시지가 삭제되지 않으므로 offset을 과거로 되돌리면 **재처리가 가능**하다.

### Partition

초당 10만 건이 하나의 줄에 순서대로 쌓이면 쓰기 병목이 발생한다. 여러 Partition으로 나눈다.

```
                    +- Partition 0: [0, 1, 2, 3, ...]
                    |
클릭 -> Topic ------+- Partition 1: [0, 1, 2, 3, ...]
                    |
                    +- Partition 2: [0, 1, 2, 3, ...]
```

```python
hash(ad_id) % 파티션_수  # -> 해당 Partition으로
```

**같은 `ad_id`의 클릭은 항상 같은 Partition** -> 같은 광고 내에서 순서 보장

**Consumer와 Partition의 관계**

| 상황 | 결과 |
|---|---|
| Partition 3개, Consumer 2개 | 한 Consumer가 2개 담당 |
| Partition 3개, Consumer 3개 | 딱 맞게 1:1 |
| Partition 3개, Consumer 5개 | **2개는 놀고 있음** |

-> **Partition 수가 병렬 처리의 상한선**

---

## 전달 보장 (Delivery Guarantees)

분산 시스템에서 메시지를 얼마나 확실하게 처리할 것인지에 대한 약속이다.

```
┌───────────────┬─────────────┬─────────────┬─────────────────────┐
│    보장 수준   │  메시지 유실 │  메시지 중복 │       사용 예시      │
├───────────────┼─────────────┼─────────────┼─────────────────────┤
│ At-most-once  │     O       │     X       │ 로그, 메트릭        │
│ At-least-once │     X       │     O       │ 알림, 이벤트 처리    │
│ Exactly-once  │     X       │     X       │ 결제, 정산          │
└───────────────┴─────────────┴─────────────┴─────────────────────┘
```

### At-most-once (최대 한 번)

메시지를 보내고 확인(Ack)을 받지 않는다. 유실 가능, 중복 없음. (Fire and forget)

### At-least-once (적어도 한 번)

메시지를 보내고 확인(Ack)을 받는다. 못 받으면 재전송. 유실 없음, **중복 가능**.

```
Producer: "메시지 보냈다!"
Consumer: 처리 완료, Ack 전송 -> (네트워크 끊김) -> Producer: Ack 못 받음
Producer: "Ack 안 왔네? 다시 보낸다!"
결과: Consumer가 같은 메시지를 두 번 받음
```

### Exactly-once (정확히 한 번)

가장 어렵다. 유실도 없고 중복도 없다.

- **Kafka**: 멱등성 프로듀서(`enable.idempotence=true`)와 트랜잭션으로 Kafka 내부적으로 보장
- **RabbitMQ**: 기본 미지원. 컨슈머단에서 중복 처리 방지 로직(Idempotency) 구현 필요

---

## 저장 정책

Kafka는 메시지를 소비해도 지우지 않는다. **정책(Policy)**에 따라 파일 시스템에 저장한다.

| 정책 | 설정 예시 | 설명 |
|---|---|---|
| 시간 기반 | `log.retention.hours=168` | 7일 동안 보관 후 삭제 |
| 크기 기반 | `log.retention.bytes=1GB` | 파티션 크기 초과 시 오래된 것부터 삭제 |

이 정책 덕분에 Kafka는 **과거 데이터 재생(Replay)**이 가능한 스토리지 시스템처럼 동작한다.

RabbitMQ는 소비되면 삭제된다. (단, RabbitMQ Streams 3.9+는 Kafka처럼 append-only 로그 지원)

---

## 처리량 vs 지연시간

### Kafka (높은 처리량)

- **배치 처리**: 메시지를 모아서 한 번에 전송/저장
- **순차 I/O**: 디스크에 append-only로 순차적으로 쓴다
- **Zero-copy**: 커널 레벨에서 데이터를 복사 없이 직접 네트워크로 전송
- **단점**: 배치 대기 시간만큼 개별 메시지 지연 증가

### RabbitMQ (낮은 지연시간)

- **즉시 전달**: 배치 없이 바로 Push
- **메모리 중심**: 빠른 접근
- **단점**: 대량 처리 시 메모리 한계, 개별 메시지 오버헤드

```
Kafka:   [msg1, msg2, msg3, msg4, msg5] --batch--> Consumer
         ~~~~~~~~~~~~ 배치 대기 ~~~~~~~~~~~~~
         처리량: 높음, 지연시간: 배치 간격만큼

RabbitMQ: msg1 --> Consumer (즉시)
          msg2 --> Consumer (즉시)
          처리량: 낮음, 지연시간: 최소
```

---

## DLQ(Dead Letter Queue) 패턴

처리에 실패한 메시지를 별도 큐/토픽으로 격리하는 패턴이다.

### RabbitMQ: 브로커 레벨 지원

```
Worker: PDF 생성 실패 -> ACK 안 보냄 -> 메시지 자동 재전달
```

큐 선언 시 `x-dead-letter-exchange`와 `x-dead-letter-routing-key` 설정하면, 거부(reject/nack)되거나 TTL 만료된 메시지가 자동으로 DLX로 라우팅된다. 별도 코드 없이 브로커 설정만으로 동작.

### Kafka: 직접 구현

Kafka는 "dumb pipes, smart endpoints" 철학. 브로커는 append-only 로그로 단순하게 유지하고, 에러 처리는 클라이언트가 담당.

```
[ad-events] --> Consumer --> 외부 API 호출
                   |
                   +-- 성공 -> commit
                   |
                   +-- 실패 -> [ad-events-dlq] 로 전송
                                    |
                                    v
                            DLQ Consumer (재시도)
```

**DLQ Best Practices**

원본 메시지 key/value는 유지하고, 실패 원인은 Kafka message header에 기록:

```python
headers = [
    ("error.cause", b"TimeoutException"),
    ("error.message", b"External API timeout after 5000ms"),
    ("error.origin.topic", b"ad-events"),
    ("error.origin.partition", b"3"),
    ("error.origin.offset", b"1542"),
]
producer.send("ad-events-dlq", key=original_key, value=original_value, headers=headers)
```

### 순서 보장 DLQ 패턴

광고 이벤트처럼 순서가 중요한 경우:

```
offset 10: "광고 123 시작" -> 실패 -> DLQ로
offset 11: "광고 123 종료" -> ???
offset 12: "광고 123 시작" -> ???
```

순서가 중요하면 offset 11, 12도 처리하면 안 된다.

```python
blocked_ad_ids: set[str] = set()

def process_event(event):
    if event.ad_id in blocked_ad_ids:
        send_to_dlq(event, reason="blocked_by_previous_failure")
        return

    success = call_external_api(event)

    if not success:
        send_to_dlq(event, reason="api_failure")
        blocked_ad_ids.add(event.ad_id)  # 이 ad_id blocked 처리
```

---

## Zookeeper 제거 (KRaft)

### Zookeeper의 원래 역할

- 브로커 등록/발견
- Controller 선출
- 토픽/파티션 메타데이터 저장
- ACL(권한) 정보

### 왜 제거했을까?

| 문제점 | 설명 |
|---|---|
| 운영 복잡성 | Kafka와 Zookeeper 두 개의 분산 시스템을 운영 |
| 확장성 한계 | Zookeeper가 병목, 파티션 수 제한 (~수만 개) |
| 장애 복구 지연 | Controller 재선출에 시간 소요 |
| 메타데이터 불일치 | Kafka-Zookeeper 간 동기화 문제 |

### KRaft 모드 (Kafka 3.0+)

Kafka 브로커들이 자체적으로 Raft 프로토콜로 합의를 수행한다.

```
Before (Zookeeper 방식):
[Broker 1] ---> [Zookeeper Cluster] <--- [Broker 2]

After (KRaft 방식):
[Controller 1] <--Raft--> [Controller 2] <--Raft--> [Controller 3]
      |                         |                         |
[Broker 1]              [Broker 2]                [Broker 3]
```

- 빠른 복구: Controller 장애 시 밀리초 단위로 새 Controller 선출
- 확장성 향상: 수백만 개의 파티션까지 지원
- Kafka 4.0에서 Zookeeper 지원 완전 제거 예정

---

## 언제 뭘 쓸까?

| 상황 | 선택 | 이유 |
|---|---|---|
| 광고 클릭/노출 스트림 | Kafka | 대용량, 재처리, 여러 시스템이 같은 데이터 필요 |
| 썸네일 생성 작업 | RabbitMQ | 소규모, 한 번 처리하면 끝, 작업 분배 |
| 정산 리포트 PDF 생성 | RabbitMQ | 실패 시 재시도 간단 (ACK 기반) |
| 이벤트 소싱/로그 수집 | Kafka | 순서 보장 + 영구 저장 + 재처리 |
| 마이크로서비스 간 RPC성 통신 | RabbitMQ | 요청-응답 패턴, 유연한 라우팅 |

---

## 성능 벤치마크

실측 기준 (3노드 클러스터, 1KB 메시지):

| 지표 | Kafka | RabbitMQ |
|------|-------|----------|
| 처리량 (Producer) | **100만 msg/sec** | 20,000 msg/sec |
| 처리량 (Consumer) | 100만 msg/sec | 30,000 msg/sec |
| 지연시간 (p99) | 5~15ms (배치) | **1~2ms** |
| 지연시간 (p99, 배치 없음) | 2~5ms | 1~2ms |

Kafka는 `linger.ms=5`, `batch.size=16KB` 기본값 기준. 배치를 줄이면 지연시간이 줄지만 처리량도 감소한다.

---

## 정리 비교표

| 항목 | Kafka | RabbitMQ |
|---|---|---|
| 메시지 보관 | 디스크에 유지 (재처리 가능) | 소비되면 삭제 |
| 여러 시스템이 같은 메시지 필요 | Consumer Group으로 자연스럽게 | Exchange 설정 필요 |
| 순서 보장 | Partition 내 보장 | 기본 보장 (단일 큐) |
| 병렬 처리 확장 | Partition 수가 상한선 | Worker 수 자유롭게 |
| 작업 단위 재시도 | DLQ 패턴 직접 구현 | ACK 기반으로 간단 |
| 처리량 | **~100만 msg/sec** | ~2만 msg/sec |
| 지연시간 | 5~15ms | **1~2ms** |
| 라우팅 | Topic 기반 | Exchange 기반 (유연함) |

---

## 자가 체크

> - 우리 시스템에서 같은 메시지를 여러 서비스가 소비하는 경우가 있는가?
> - Consumer Group 이름과 구성을 파악하고 있는가?
> - Partition 수와 key 설정이 순서 보장이 필요한 필드로 되어 있는가?
> - DLQ가 존재하는가? 존재한다면 모니터링과 재처리 로직이 있는가?
> - 순서 보장이 필요한 경우, 실패 시 해당 key의 후속 메시지를 block하고 있는가?
> - offset commit 시점이 자동인가 수동인가? 의도한 것인가?


---
layout: post
title: "광고 도메인 예시로 이해하는 Kafka vs RabbitMQ"
date: 2026-01-28 10:00:00 +0900
categories: [backend, messaging]
---

"같은 클릭 이벤트를 여러 시스템이 동시에 필요로 한다면?" — 광고 도메인은 메시지 브로커의 차이를 체감하기 좋은 예시다. 이 글에서는 Kafka와 RabbitMQ의 근본적인 차이를 광고 시스템 시나리오로 풀어본다.

## 먼저 생각해볼 것

> - 메시지를 한 번 소비하면 끝인가, 여러 시스템이 같은 메시지를 각자 필요로 하는가?
> - 처리 실패 시 재시도는 어떻게 하는가? 순서가 중요한가?
> - 과거 데이터를 다시 처리해야 할 일이 있는가?
> - 초당 처리량은 어느 정도인가?

---

## 메시지 소비 방식의 근본적 차이

| | RabbitMQ (기본) | Kafka |
|---|---|---|
| 메시지 소비 | Consumer가 가져가면 **삭제됨** | Consumer가 읽어도 **유지됨** |
| 비유 | 택배 수령 (가져가면 끝) | 게시판 열람 (누가 봐도 글은 그대로) |
| 저장 방식 | 메모리 중심 | 디스크에 로그처럼 저장 |
| 전달 모델 | **Push** — 브로커가 Consumer에게 밀어줌 | **Pull** — Consumer가 브로커에서 당겨감 |

RabbitMQ는 메시지가 도착하면 즉시 Consumer에게 push한다. Consumer는 `prefetch_count`로 한 번에 받을 수 있는 미확인 메시지 수를 제한한다. 반면 Kafka는 Consumer가 직접 batch 단위로 pull하며, 데이터가 없을 때는 long-polling으로 대기한다.

### 광고 클릭 시나리오로 이해하기

```
광고 클릭 이벤트 발생 -> 여러 시스템이 필요로 함:
- 정산 시스템: 광고주에게 비용 청구
- 분석 시스템: 클릭률(CTR) 집계
- 실시간 대시보드: 광고주가 보는 현황판
```

**Kafka**: 세 시스템 모두 같은 이벤트를 **각자 독립적으로** 받을 수 있음 (Consumer Group)
**RabbitMQ**: 기본적으로 하나가 가져가면 사라짐 (Fanout Exchange 설정으로 유사하게 가능)

---

## Consumer Group

### 문제 상황

정산 서버가 3대인데, 같은 클릭 이벤트를 3대 모두 처리하면?
-> 100원짜리 클릭이 300원으로 과청구!

### Kafka의 해결책: Consumer Group

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

### 핵심 규칙

- **같은 Consumer Group 내에서는** -> 이벤트를 나눠 가짐 (중복 처리 방지)
- **다른 Consumer Group끼리는** -> 같은 이벤트를 각자 받음

---

## Offset: 어디까지 읽었는지 추적

메시지가 순서대로 쌓이므로, 각 메시지에 번호(offset)가 붙는다: 0, 1, 2, 3...

```
"정산 그룹은 offset 1542까지 읽었다"
```

Kafka는 Consumer의 현재 위치를 `__consumer_offsets`라는 내부 토픽에 저장한다.

### 재처리가 가능한 이유

Kafka는 메시지가 삭제되지 않으므로, offset을 과거로 되돌리면 다시 읽을 수 있다.

> **PM**: "지난주 데이터 다시 분석해줘"
> **분석팀**: offset 되돌려서 재처리 가능

RabbitMQ는 이미 사라져서 불가능 (단, RabbitMQ Streams를 사용하면 가능 — 아래 정리 비교표 참고)

---

## Partition: 병렬 처리의 핵심

### 왜 필요한가?

초당 10만 건이 하나의 줄에 순서대로 쌓이면 -> 쓰기(write) 병목 발생

### 해결책: 여러 줄(Partition)로 나누기

```
                    +- Partition 0: [0, 1, 2, 3, ...]
                    |
클릭 -> Topic ------+- Partition 1: [0, 1, 2, 3, ...]
                    |
                    +- Partition 2: [0, 1, 2, 3, ...]
```

### Partition 분배 방식

```python
hash(ad_id) % 파티션_수  # -> 해당 Partition으로
```

**같은 `ad_id`의 클릭은 항상 같은 Partition** -> 같은 광고 내에서 순서 보장

### Consumer와 Partition의 관계

```
Partition 0 <-- Consumer A
Partition 1 <-- Consumer B
Partition 2 <-- Consumer C
```

**핵심 규칙**: 하나의 Partition은 같은 Consumer Group 내에서 **딱 하나의 Consumer만** 읽을 수 있음

| 상황 | 결과 |
|---|---|
| Partition 3개, Consumer 2개 | 한 Consumer가 2개 담당 |
| Partition 3개, Consumer 3개 | 딱 맞게 1:1 |
| Partition 3개, Consumer 5개 | **2개는 놀고 있음** |

-> **Partition 수가 병렬 처리의 상한선**

### Partition 수 변경 시 주의점

Partition을 10개에서 15개로 늘리면:

- 기존 데이터: 재배치되지 않음
- 새 데이터: `hash(ad_id) % 15`로 분배

```
[변경 전] ad_789 -> hash(ad_789) % 10 = Partition 3
[변경 후] ad_789 -> hash(ad_789) % 15 = Partition 8
```

**같은 `ad_id`인데 다른 Partition으로 -> 순서 보장 깨짐**

처음부터 예상 최대 Consumer 수 x 2~3배 정도로 넉넉하게 잡되, 너무 많으면 각 Partition마다 디스크 파일, 메모리 버퍼, 파일 핸들이 필요하므로 리소스 낭비에 주의한다.

---

## DLQ(Dead Letter Queue) 패턴

처리에 실패한 메시지를 별도 큐/토픽으로 격리하는 패턴이다.

### RabbitMQ: ACK 기반 재시도

```
Worker: PDF 생성 실패 -> ACK 안 보냄 -> 메시지 자동 재전달
```

RabbitMQ는 브로커 레벨에서 Dead Letter Exchange(DLX)를 지원한다. 큐 선언 시 `x-dead-letter-exchange`와 `x-dead-letter-routing-key`를 설정하면, 거부(reject/nack)되거나 TTL이 만료된 메시지가 자동으로 DLX로 라우팅된다. 별도 코드 없이 브로커 설정만으로 동작한다.

### Kafka: DLQ 직접 구현

Kafka는 "dumb pipes, smart endpoints" 철학을 따른다. 브로커는 append-only 로그로 최대한 단순하게 유지하고, 에러 처리와 라우팅 로직은 클라이언트에 맡긴다. 따라서 DLQ를 직접 구현해야 한다.

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

#### 왜 까다로운가?

```
offset 5 처리 실패 -> 근데 offset 6, 7은 이미 처리됨
                   -> 5만 다시 처리하려면? 별도 설계 필요
```

### DLQ Best Practices

**원본 메시지 보존**: 실패한 메시지를 DLQ 토픽에 보낼 때 key/value는 변경하지 않는다. 실패 원인은 Kafka message header에 기록한다.

```python
headers = [
    ("error.cause", b"TimeoutException"),
    ("error.message", b"External API timeout after 5000ms"),
    ("error.origin.topic", b"ad-events"),
    ("error.origin.partition", b"3"),
    ("error.origin.offset", b"1542"),
    ("error.timestamp", b"2026-01-28T10:30:00Z"),
]
producer.send("ad-events-dlq", key=original_key, value=original_value, headers=headers)
```

**DLQ 모니터링**: DLQ로 보내기만 하고 방치하면 의미가 없다. 다음을 모니터링한다:

- DLQ 토픽의 메시지 증가율 (급증 시 알림)
- 메시지 체류 시간 (오래된 메시지가 쌓이고 있지 않은지)
- 에러 유형별 빈도 (특정 에러가 반복되면 근본 원인 해결)

### Kafka Connect의 DLQ 지원

Kafka Connect는 2.0부터 sink connector에 대해 DLQ를 설정으로 지원한다:

```json
{
  "errors.tolerance": "all",
  "errors.deadletterqueue.topic.name": "dlq-my-connector",
  "errors.deadletterqueue.topic.replication.factor": 3,
  "errors.deadletterqueue.context.headers.enable": true
}
```

- `errors.tolerance=all`: 에러 발생 시 해당 레코드를 건너뛰고 계속 처리
- `errors.deadletterqueue.context.headers.enable=true`: 실패 원인을 header에 자동 기록

주의: Kafka Connect DLQ는 **역직렬화/변환 에러**만 처리한다. sink에 쓰는 단계(`put`)에서 발생한 에러는 DLQ로 가지 않고 task가 실패한다.

### KIP-1034: Kafka Streams 네이티브 DLQ

Kafka Streams에서도 네이티브 DLQ 지원이 추가된다. 기존에는 예외 발생 시 "로그 남기고 건너뛰기" 또는 "즉시 중단" 두 가지뿐이었다.

KIP-1034는 `DeserializationExceptionHandler`, `ProductionExceptionHandler`, `ProcessingExceptionHandler` 세 가지 핸들러 모두에서 실패한 레코드를 DLQ 토픽으로 라우팅할 수 있게 한다. 원본 key/value는 유지하고 에러 정보는 header에 자동 추가된다. Apache Kafka 4.2.0에 포함 예정이다.

### 순서 보장 DLQ 패턴

광고 이벤트는 순서가 중요할 수 있다: 시작 -> 종료 -> 시작 (반복)

```
offset 10: "광고 123 시작" -> 실패 -> DLQ로
offset 11: "광고 123 종료" -> ???
offset 12: "광고 123 시작" -> ???
```

순서가 중요하면 offset 11, 12도 처리하면 안 된다.

| 전략 | 동작 | 순서 보장 |
|---|---|---|
| 단순 DLQ | 실패한 것만 DLQ, 나머지 계속 | X |
| 순서 보장 DLQ | 실패 시 해당 `ad_id` blocked | O |

#### 순서 보장 DLQ 구현 핵심

```python
blocked_ad_ids: set[str] = set()

def process_event(event):
    if event.ad_id in blocked_ad_ids:
        # 바로 DLQ로 전송 (처리하지 않음)
        send_to_dlq(event, reason="blocked_by_previous_failure")
        return

    success = call_external_api(event)

    if not success:
        send_to_dlq(event, reason="api_failure")
        blocked_ad_ids.add(event.ad_id)  # 이 ad_id blocked 처리
```

같은 `ad_id`의 메시지가 같은 Partition에 들어가므로 (hash 기반 분배), 하나의 Consumer 내에서 `blocked_ad_ids` set으로 관리할 수 있다.

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

## 정리 비교표

| 항목 | Kafka | RabbitMQ |
|---|---|---|
| 메시지 보관 | 디스크에 유지 (재처리 가능) | 소비되면 삭제 |
| 여러 시스템이 같은 메시지 필요 | Consumer Group으로 자연스럽게 | Exchange 설정 필요 |
| 순서 보장 | Partition 내 보장 | 기본 보장 (단일 큐) |
| 병렬 처리 확장 | Partition 수가 상한선 | Worker 수 자유롭게 |
| 작업 단위 재시도 | DLQ 패턴 직접 구현 | ACK 기반으로 간단 |
| 적합한 규모 | 대용량 스트리밍 (~1M msg/sec) | 소~중규모 작업 큐 (~4K-10K msg/sec) |
| 확장 방식 | Partition 기반 수평 확장 | 수직 + 수평 확장 |
| 라우팅 | Topic 기반 | Exchange 기반 (유연함) |

### RabbitMQ의 Exchange 라우팅 방식

RabbitMQ에서 Producer는 메시지를 큐에 직접 보내지 않는다. Exchange에 보내면 Exchange가 바인딩 규칙에 따라 큐로 라우팅한다.

| Exchange 타입 | 라우팅 방식 |
|---|---|
| **Direct** | routing key가 정확히 일치하는 큐로 전달 |
| **Topic** | 와일드카드 패턴 매칭 (`*`: 한 단어, `#`: 0개 이상) |
| **Fanout** | 바인딩된 모든 큐에 브로드캐스트 (routing key 무시) |
| **Headers** | 메시지 header 속성 기반 매칭 (`x-match: all` 또는 `any`) |

### RabbitMQ Streams (3.9+)

RabbitMQ 3.9부터 Streams라는 새로운 데이터 구조가 추가되었다. append-only 불변 로그로, 메시지를 읽어도 삭제되지 않는다. offset 기반으로 과거 메시지를 다시 읽을 수 있어서 Kafka의 로그 모델과 유사하다. RabbitMQ 3.11부터는 Super Streams로 파티셔닝도 지원한다.

다만 log compaction은 지원하지 않고, 대규모 스트리밍에서는 Kafka가 더 적합하다.

---

## 현실적 선택

> "이론적으로 더 나은 도구" vs "이미 있는 도구"

회사에 Kafka 인프라가 있으면 -> Kafka로 DLQ 패턴 구현
RabbitMQ가 이론적으로 더 적합해도, 새 인프라 구축 비용 고려

둘 다 없는 상태에서 시작한다면:

- 이벤트 스트리밍이 주 목적이면 -> Kafka
- 작업 큐가 주 목적이면 -> RabbitMQ
- 둘 다 필요하면 -> Kafka (RabbitMQ Streams가 작업 큐 일부를 커버할 수 있지만, Kafka의 생태계가 더 성숙)

---

## 자가 체크

> - 우리 시스템에서 같은 메시지를 여러 서비스가 소비하는 경우가 있는가?
> - Consumer Group 이름과 구성을 파악하고 있는가?
> - Partition 수와 key 설정이 순서 보장이 필요한 필드로 되어 있는가?
> - DLQ가 존재하는가? 존재한다면 모니터링과 재처리 로직이 있는가?
> - 순서 보장이 필요한 경우, 실패 시 해당 key의 후속 메시지를 block하고 있는가?
> - offset commit 시점이 자동인가 수동인가? 의도한 것인가?

---

## 참고 자료

- [AWS - Amazon MQ에서 Kafka와 RabbitMQ 비교](https://aws.amazon.com/compare/the-difference-between-rabbitmq-and-kafka/)
- [Confluent - Kafka Dead Letter Queue](https://www.confluent.io/learn/kafka-dead-letter-queue/)
- [Confluent - Kafka Connect Deep Dive: Error Handling and Dead Letter Queues](https://www.confluent.io/blog/kafka-connect-deep-dive-error-handling-dead-letter-queues/)
- [Apache Kafka - KIP-1034: Dead Letter Queue in Kafka Streams](https://cwiki.apache.org/confluence/display/KAFKA/KIP-1034:+Dead+letter+queue+in+Kafka+Streams)

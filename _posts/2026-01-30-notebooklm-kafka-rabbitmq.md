---
layout: post
title: "NotebookLM으로 공부하는 Kafka vs RabbitMQ"
date: 2026-01-30 10:00:00 +0900
categories: [backend, messaging]
---

Kafka와 RabbitMQ의 차이를 공부하기 위해 [NotebookLM](https://notebooklm.google.com/)을 사용해봤다. 이해가 안 되거나 궁금한 것들을 질문해가며 정리한 내용이다.

---

## 메시지 브로커의 정의는 정확히 뭘까?

메시지 브로커는 **애플리케이션, 시스템, 서비스 간의 통신을 중개하는 미들웨어 소프트웨어**다.

- **역할**: 발신자와 수신자가 서로의 위치나 상태(활성 여부)를 알 필요 없이 데이터를 주고 받을 수 있게 해준다 (디커플링, 결합도 감소)
- **기능**: 메시지의 유효성 검사, 라우팅(경로 지정), 저장(버퍼링), 그리고 다른 프로토콜 간의 변환 역할도 수행한다
- **비유**: 우체국. 편지를 보내는 사람(producer)은 받는 사람(consumer)이 집에 있는지 없는지 신경 쓰지 않고 우체통(broker)에 넣기만 하면 된다

---

## AMQP 프로토콜은 뭐지? 표준 스펙이 제안된 건가?

**AMQP(Advanced Message Queuing Protocol)**는 메시지 지향 미들웨어를 위한 개방형 표준 응용 계층 프로토콜이다.

- **표준 여부**: ISO/IEC 국제 표준으로 제안된 스펙이다. RabbitMQ는 기본적으로 AMQP 0.91 버전을 사용하며, 플러그인을 통해 AMQP 1.0도 지원한다
- **특징**: 단순히 메시지 전송 형식만 정의하는 것이 아니라, 브로커 내부의 동작 방식(Exchange, Queue, Binding 등)까지 정의한다. 이 때문에 서로 다른 언어나 플랫폼으로 개발된 클라이언트들이 문제없이 통신할 수 있는 상호운용성을 보장한다

---

## 왜 Push, Pull 방식이라고 하는 걸까?

이 차이는 시스템의 설계 철학인 **"누가 데이터의 흐름을 제어하는가"**에서 비롯된다.

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

### RabbitMQ (Push 방식 - Smart Broker, Dumb Consumer)

- **방식**: 브로커가 큐에 메시지가 들어오자마자 연결된 컨슈머에게 즉시 밀어 넣는다 (Push)
- **이유**: 지연 시간(Latency)을 최소화하기 위함이다. 단, 컨슈머가 처리할 수 있는 양보다 더 많이 보내면 문제가 생길 수 있어 prefetch limit(한 번에 보낼 양 제한)을 설정하여 흐름을 제어한다

### Kafka (Pull 방식 - Dumb Broker, Smart Consumer)

- **방식**: 컨슈머가 브로커에게 "나 지금 처리 가능하니 데이터를 달라"고 요청해서 가져온다 (Pull)
- **이유**: Kafka는 대량의 배치(Batch) 처리를 위해 설계되었다. 컨슈머가 자신의 처리 능력에 맞춰 속도를 조절할 수 있고, 장애가 발생해도 브로커에 데이터가 그대로 있으므로 나중에 다시 가져올 수 있다

---

## Exchange와 Queue가 언제 어떻게 활용될 수 있을지 감이 안 온다

**복잡한 라우팅**을 구현하는 핵심 요소들이다. 기차역 비유가 가장 이해하기 쉽다.

- **Exchange (중앙 기차역/우편물 분류 센터)**: 생산자가 보낸 메시지를 가장 먼저 받는 곳이다. 메시지를 어떤 큐로 보낼지 결정하는 라우팅 로직만 담당하며, 메시지를 저장하지는 않는다
- **Queue (플랫폼/우편함)**: 메시지가 소비되기 전까지 실제로 저장되는 버퍼다
- **Binding (기차 시간표/배송 규칙)**: Exchange와 Queue를 연결하는 규칙이다. "이 조건(Routing Key)에 맞는 메시지는 저 큐로 보내라"고 정의하는 것이다

### 활용 예시

하나의 로그 메시지(생산자)를 Exchange에 보냈을 때, Binding 설정에 따라 '에러 로그 큐'와 '전체 로그 아카이빙 큐' 두 곳으로 동시에 복제되어 전달될 수 있다.

```
Producer -> [Exchange] --binding--> [에러 로그 큐] --> 알림 서비스
                       --binding--> [전체 로그 큐] --> 아카이빙 서비스
```

---

## Kafka 정책 기반 영구 저장이라면 어떤 정책들이 있는 거지?

Kafka는 메시지를 소비했다고 해서 지우지 않는다. **설정된 정책(Policy)**에 따라 파일 시스템에 저장한다.

| 정책 | 설정 예시 | 설명 |
|---|---|---|
| 시간 기반 | `log.retention.hours=168` | 7일 동안 보관 후 삭제 |
| 크기 기반 | `log.retention.bytes=1GB` | 토픽 파티션 크기가 1GB를 넘으면 가장 오래된 데이터부터 삭제 |

이 정책 덕분에 Kafka는 단순한 큐가 아니라 **"과거 데이터 재생(Replay)"**이 가능한 스토리지 시스템처럼 동작할 수 있다.

---

## 전달 보장(Delivery Guarantees)을 상황 기반으로 이해하고 싶어

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

메시지를 보내고 확인(Ack)을 받지 않는다. 메시지가 유실될 수 있지만 중복은 없다. (Fire and forget)

```
Producer: "메시지 보냈다!" -> (네트워크 끊김) -> Consumer: 못 받음
결과: 메시지 유실, 재전송 없음
```

**적합한 경우**: 로그 수집, 메트릭 전송 등 일부 유실이 허용되는 경우

### At-least-once (적어도 한 번)

메시지를 보내고 확인(Ack)을 받는다. 확인을 못 받으면 재전송한다. 메시지 유실은 없지만, **중복 전송**될 수 있다.

```
Producer: "메시지 보냈다!"
Consumer: 처리 완료, Ack 전송 -> (네트워크 끊김) -> Producer: Ack 못 받음
Producer: "Ack 안 왔네? 다시 보낸다!"
결과: Consumer가 같은 메시지를 두 번 받음
```

**적합한 경우**: 멱등성(Idempotency)이 보장되는 작업. 예를 들어 같은 데이터를 덮어쓰는 경우

### Exactly-once (정확히 한 번)

가장 어렵다. 메시지 유실도 없고 중복도 없다.

- **Kafka**: '멱등성 프로듀서(Idempotent Producer)'와 '트랜잭션(Transaction)' 기능을 통해 Kafka 내부적으로 정확히 한 번 기록됨을 보장한다
- **RabbitMQ**: 기본적으로는 지원하지 않으며, 컨슈머단에서 중복 처리를 방지하는 로직(Idempotency)을 구현해야 한다

```
# Kafka 멱등성 프로듀서 설정
enable.idempotence=true
```

---

## 처리량은 Kafka가 훨씬 높은데 지연시간은 RabbitMQ가 더 유리해 보여. 그 이유가 뭘까?

### Kafka (높은 처리량 High Throughput)

- **배치 처리**: 메시지를 모아서 한 번에 전송/저장한다. 개별 메시지마다 I/O를 수행하지 않아 효율적이다
- **순차 I/O**: 디스크에 append-only로 순차적으로 쓴다. 랜덤 I/O보다 훨씬 빠르다
- **Zero-copy**: 커널 레벨에서 데이터를 복사 없이 직접 네트워크로 전송한다
- **단점**: 배치를 모으는 시간 동안 대기가 발생하므로 개별 메시지의 지연시간은 길어질 수 있다

### RabbitMQ (낮은 지연시간 Low Latency)

- **즉시 전달**: 메시지가 도착하면 배치를 기다리지 않고 바로 컨슈머에게 Push한다
- **메모리 중심**: 메시지를 메모리에 유지하므로 빠른 접근이 가능하다
- **단점**: 대량 처리 시 메모리 한계에 부딪히고, 개별 메시지마다 처리 오버헤드가 발생한다

```
지연시간 vs 처리량 트레이드오프:

Kafka:   [msg1, msg2, msg3, msg4, msg5] --batch--> Consumer
         ~~~~~~~~~~~~ 배치 대기 ~~~~~~~~~~~~~
         처리량: 높음, 지연시간: 배치 간격만큼

RabbitMQ: msg1 --> Consumer (즉시)
          msg2 --> Consumer (즉시)
          처리량: 낮음, 지연시간: 최소
```

---

## Zookeeper를 제거했다고 하는데 그 이유가 뭐고 원래 어떤 역할을 했는지도 알아둬야 할 것 같아

### Zookeeper의 원래 역할

Kafka는 분산 시스템이라 여러 브로커가 협력해야 한다. Zookeeper는 이 협력을 조율하는 역할을 했다:

- **브로커 등록/발견**: 어떤 브로커가 살아있는지 관리
- **Controller 선출**: 브로커 중 리더 역할을 할 Controller 선출
- **토픽/파티션 메타데이터**: 토픽이 어떤 파티션으로 구성되어 있는지, 각 파티션의 리더가 누구인지 저장
- **ACL(권한) 정보**: 접근 제어 목록 저장

### 왜 제거했을까? (KRaft 모드)

Kafka 3.0부터 Zookeeper 없이 동작하는 **KRaft(Kafka Raft)** 모드가 도입되었다.

| 문제점 | 설명 |
|---|---|
| 운영 복잡성 | Kafka와 Zookeeper 두 개의 분산 시스템을 운영해야 함 |
| 확장성 한계 | Zookeeper가 병목이 되어 파티션 수 제한 (~수만 개) |
| 장애 복구 지연 | Controller 장애 시 Zookeeper를 통한 재선출에 시간 소요 |
| 메타데이터 불일치 | Kafka와 Zookeeper 간 메타데이터 동기화 문제 |

### KRaft 모드의 장점

- **단일 시스템**: Kafka 브로커들이 자체적으로 합의(Raft 프로토콜)를 수행
- **빠른 복구**: Controller 장애 시 밀리초 단위로 새 Controller 선출
- **확장성 향상**: 수백만 개의 파티션까지 지원 가능
- **운영 단순화**: Zookeeper 클러스터 관리 불필요

```
Before (Zookeeper 방식):
[Broker 1] ---> [Zookeeper Cluster] <--- [Broker 2]
[Broker 3] --->                     <--- [Broker 4]

After (KRaft 방식):
[Controller 1] <--Raft--> [Controller 2] <--Raft--> [Controller 3]
      |                         |                         |
[Broker 1]              [Broker 2]                [Broker 3]
```

Kafka 3.3부터 프로덕션에서 KRaft 사용이 권장되며, Kafka 4.0에서 Zookeeper 지원이 완전히 제거될 예정이다.

---

## 참고 자료

### 메시지 브로커 기초
- [AWS - What is a Message Broker?](https://aws.amazon.com/what-is/message-broker/)
- [Red Hat - What is a message broker?](https://www.redhat.com/en/topics/integration/what-is-a-message-broker)

### AMQP 프로토콜
- [RabbitMQ - AMQP 0-9-1 Model Explained](https://www.rabbitmq.com/tutorials/amqp-concepts.html)
- [OASIS AMQP 1.0 Specification](https://docs.oasis-open.org/amqp/core/v1.0/amqp-core-overview-v1.0.html)

### RabbitMQ Exchange와 라우팅
- [RabbitMQ - Exchanges](https://www.rabbitmq.com/tutorials/tutorial-four-python.html)
- [CloudAMQP - RabbitMQ Exchange Types](https://www.cloudamqp.com/blog/part4-rabbitmq-for-beginners-exchanges-routing-keys-bindings.html)

### Kafka 저장 정책
- [Apache Kafka - Log Retention](https://kafka.apache.org/documentation/#brokerconfigs_log.retention.hours)
- [Confluent - Kafka Log Compaction](https://docs.confluent.io/platform/current/kafka/design.html#log-compaction)

### 전달 보장 (Delivery Guarantees)
- [Kafka - Message Delivery Semantics](https://kafka.apache.org/documentation/#semantics)
- [Confluent - Exactly-Once Semantics](https://www.confluent.io/blog/exactly-once-semantics-are-possible-heres-how-apache-kafka-does-it/)
- [RabbitMQ - Consumer Acknowledgements](https://www.rabbitmq.com/docs/confirms)

### Push vs Pull 모델
- [Kafka Documentation - Push vs Pull](https://kafka.apache.org/documentation/#design_pull)
- [RabbitMQ - Consumer Prefetch](https://www.rabbitmq.com/docs/consumer-prefetch)

### Zookeeper 제거와 KRaft
- [Apache Kafka - KRaft Overview](https://kafka.apache.org/documentation/#kraft)
- [Confluent - Why Apache Kafka Doesn't Need ZooKeeper Anymore](https://www.confluent.io/blog/removing-zookeeper-dependency-in-kafka/)
- [KIP-500: Replace ZooKeeper with a Self-Managed Metadata Quorum](https://cwiki.apache.org/confluence/display/KAFKA/KIP-500%3A+Replace+ZooKeeper+with+a+Self-Managed+Metadata+Quorum)

### Kafka vs RabbitMQ 비교
- [AWS - Amazon MQ에서 Kafka와 RabbitMQ 비교](https://aws.amazon.com/compare/the-difference-between-rabbitmq-and-kafka/)
- [Confluent - Kafka vs RabbitMQ](https://www.confluent.io/learn/kafka-vs-rabbitmq/)

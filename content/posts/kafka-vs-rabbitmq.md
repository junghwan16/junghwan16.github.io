---
title: "Kafka와 RabbitMQ는 무엇이 다른가"
url: "/backend/messaging/2026/01/30/kafka-vs-rabbitmq/"
date: 2026-01-30 10:00:00 +0900
categories: [backend, messaging]
---

Kafka와 RabbitMQ는 둘 다 메시지를 전달하지만, 같은 문제를 푸는 도구는 아니다. RabbitMQ는 **작업을 한 소비자에게 맡기는 큐**에 가깝고, Kafka는 **이벤트를 오래 남겨 여러 소비자가 읽는 로그**에 가깝다.

선택 기준도 여기서 갈린다. 메시지를 처리한 뒤 사라져도 되면 RabbitMQ가 자연스럽다. 나중에 다시 읽거나, 여러 시스템이 같은 이벤트를 각자 처리해야 한다면 Kafka가 자연스럽다.

## 결론 먼저

| 질문 | RabbitMQ가 맞는 쪽 | Kafka가 맞는 쪽 |
|---|---|---|
| 메시지 성격 | 처리해야 할 작업(command) | 이미 일어난 사실(event) |
| 소비 방식 | 한 작업을 한 worker가 처리 | 여러 consumer group이 같은 이벤트를 각자 읽음 |
| 처리 후 상태 | ACK 후 큐에서 제거 | 보관 기간 동안 로그에 유지 |
| 재처리 | 실패한 메시지 재시도 중심 | offset을 되돌려 과거 이벤트 재생 |
| 라우팅 | exchange, routing key, header 기반 라우팅 | topic, partition key 중심 |
| 확장 기준 | worker 수를 늘려 큐를 비움 | partition 수가 병렬 처리 상한 |

짧게 말하면 이렇다.

- **RabbitMQ**: "이 작업을 누가 처리할 것인가?"
- **Kafka**: "이 이벤트를 누가 어디까지 읽었는가?"

## RabbitMQ는 큐다

RabbitMQ에서 메시지는 큐에 들어가고, consumer가 처리한 뒤 ACK를 보내면 큐에서 빠진다.

이 모델은 작업 분배에 잘 맞는다.

예를 들어 이미지 썸네일 생성 작업을 생각해보자.

```text
이미지 업로드 -> thumbnail.queue -> worker 1
                              -> worker 2
                              -> worker 3
```

작업 하나는 worker 하나만 처리하면 된다. 실패하면 다시 큐에 넣거나 dead letter queue로 보낸다. 성공한 작업을 몇 시간 뒤 다시 읽을 필요도 없다. 이런 경우 Kafka의 로그 보관과 offset 관리는 오히려 부담이다.

RabbitMQ의 강점은 세밀한 라우팅이다. direct, topic, fanout, headers exchange를 조합하면 "에러 로그는 알림 큐로, 전체 로그는 아카이브 큐로" 같은 구성을 브로커 레벨에서 표현할 수 있다.

## Kafka는 로그다

Kafka에서 메시지는 topic의 partition에 append-only 로그로 쌓인다. consumer가 읽어도 바로 삭제되지 않고, consumer group이 자신이 어디까지 읽었는지 offset으로 기록한다.

이 모델은 이벤트 스트림에 잘 맞는다.

```text
orders topic
  -> billing consumer group
  -> analytics consumer group
  -> dashboard consumer group
```

주문 완료 이벤트 하나를 정산 시스템, 분석 시스템, 실시간 대시보드가 모두 필요로 할 수 있다. Kafka에서는 각 시스템을 다른 consumer group으로 두면 된다. 한 그룹 안에서는 partition을 나눠 처리하고, 다른 그룹은 같은 이벤트를 독립적으로 다시 읽는다.

또 중요한 차이는 재처리다. 집계 로직에 버그가 있었다면 offset을 과거로 되돌려 이벤트를 다시 읽을 수 있다. RabbitMQ의 일반 큐 모델에서는 이미 ACK된 메시지를 그렇게 되살릴 수 없다.

## 선택 예시

| 상황 | 선택 | 이유 |
|---|---|---|
| 이미지 리사이즈, 이메일 발송, PDF 생성 | RabbitMQ | 한 번 성공하면 끝나는 작업 큐 |
| 주문/결제 이벤트 수집 | Kafka | 여러 시스템이 같은 이벤트를 읽고, 재처리도 필요 |
| 서비스 간 요청-응답성 비동기 작업 | RabbitMQ | 라우팅과 ACK 기반 재시도가 단순 |
| 로그 수집, 이벤트 소싱, 분석 파이프라인 | Kafka | 보관, 재생, 순서 있는 스트림 처리 |
| 소규모 알림 fanout | RabbitMQ | exchange로 라우팅을 명확히 표현 |

## 자주 헷갈리는 지점

RabbitMQ도 fanout을 할 수 있다. 다만 consumer마다 큐를 따로 만들고, 메시지가 ACK되면 사라지는 큐 모델이다. "새 consumer가 나중에 붙어서 과거 이벤트를 읽는다"는 요구에는 Kafka가 더 자연스럽다.

Kafka도 작업 큐처럼 쓸 수 있다. 하지만 메시지별 재시도, 지연 재시도, dead letter topic, poison message 처리는 애플리케이션 쪽 규율이 필요하다. 특히 partition 안의 순서가 중요하다면 실패한 메시지 하나가 뒤 메시지 처리 정책까지 흔든다.

Exactly-once도 이름만 보고 고르면 안 된다. Kafka의 exactly-once는 주로 Kafka 안에서 consume-transform-produce 하는 파이프라인에 대한 보장이다. 외부 DB나 외부 API까지 포함하면 결국 idempotency key, 중복 처리 방지 테이블, 트랜잭션 경계 설계가 필요하다.

성능 수치도 단독 기준이 되기 어렵다. 메시지 크기, batching, persistence, replication, consumer 처리 시간에 따라 결과가 크게 바뀐다. 도구 선택은 "초당 몇 건"보다 "메시지를 다시 읽어야 하는가", "한 이벤트를 여러 시스템이 독립적으로 소비하는가", "실패를 어디서 다룰 것인가"를 먼저 봐야 한다.

## 판단 규칙

아래 질문에 Kafka 쪽 답이 많으면 Kafka를 고른다.

- 같은 이벤트를 여러 시스템이 독립적으로 읽어야 하는가?
- 며칠 뒤 같은 데이터를 다시 처리해야 하는가?
- consumer가 각자 읽은 위치를 관리해야 하는가?
- partition key 기준 순서 보장이 중요한가?
- 로그 수집, 분석, 이벤트 소싱처럼 데이터 흐름 자체가 중요한가?

아래 질문에 RabbitMQ 쪽 답이 많으면 RabbitMQ를 고른다.

- 메시지는 처리해야 할 작업인가?
- 성공한 메시지는 사라져도 되는가?
- 실패한 작업을 ACK/NACK과 DLQ로 단순하게 다루고 싶은가?
- routing key나 header로 큐를 세밀하게 나누고 싶은가?
- 운영 규모가 크지 않은 비동기 작업 큐가 필요한가?

정리하면, **RabbitMQ는 해야 할 일을 나눠주는 도구**이고 **Kafka는 일어난 일을 오래 남겨 여러 곳에서 읽게 하는 도구**다.

## 참고자료

- [Apache Kafka Documentation](https://kafka.apache.org/documentation/)
- [RabbitMQ Documentation](https://www.rabbitmq.com/docs)
- [RabbitMQ AMQP 0-9-1 Model Explained](https://www.rabbitmq.com/tutorials/amqp-concepts)
- [Kafka Design](https://kafka.apache.org/documentation/#design)

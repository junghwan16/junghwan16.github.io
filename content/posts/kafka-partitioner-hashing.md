---
title: "같은 key인데 파티션이 다르다: 카프카 파티셔너 해싱 함정"
url: "/backend/messaging/2026/07/18/kafka-partitioner-hashing/"
date: 2026-07-18 10:00:00 +0900
categories: [backend, messaging]
---

카프카에서 "같은 key는 같은 파티션으로 가서 순서가 보장된다"는 자주 인용되는 문장이다. 그런데 이 보장은 생각보다 깨지기 쉽다. 특히 여러 언어의 클라이언트가 한 토픽에 쓸 때, **같은 key가 다른 파티션에 떨어진다.** 에러도 안 난다. 그래서 더 위험하다.

## 파티션은 누가 정하나

먼저 짚을 것. 어느 파티션에 쓸지는 **브로커가 아니라 프로듀서(클라이언트)가 정한다.** 프로듀서의 파티셔너가 `hash(key) % 파티션수`를 계산해 파티션 번호를 찍고, 브로커는 그 번호대로 저장할 뿐 재계산하지 않는다.

문제는 이 `hash`가 클라이언트마다 다르다는 데 있다.

## 기본 해시가 세 갈래다

"카프카 기본 파티셔너"라는 단일 규칙은 없다. 클라이언트 계열마다 기본 해시 함수가 다르다.

| 클라이언트 | 기본 해시 |
|---|---|
| Java 공식 클라이언트 | murmur2 |
| librdkafka 계열 (confluent-kafka-python/go/.NET) | CRC32 |
| segmentio/kafka-go, Sarama | FNV-1a |

셋이 서로 다르다. 그래서 같은 `user-42`를 Java·Python·Go에서 각각 보내면 서로 다른 파티션에 들어갈 수 있다.

Confluent의 [Standardized Hashing 글](https://www.confluent.io/blog/standardized-hashing-across-java-and-non-java-producers/)은 실제 사고 사례를 든다. Python 프로듀서와 ksqlDB 스트림이 같은 user ID로 조인이 안 됐고, 원인은 murmur2(Java) vs CRC32(librdkafka) 해시 불일치였다. Kafka 커미터 Bill Bejeck도 [같은 함정](https://bbejeck.medium.com/a-critical-detail-about-kafka-partitioners-8e17dfd45a7)을 지적하며 "기본값이 있으니 괜찮겠지라는 가정을 버리라"고 말한다.

## 함정은 사실 두 개다

| 함정 | 언제 터지나 | 방어 |
|---|---|---|
| 클라이언트 간 해시 불일치 | 여러 언어 프로듀서가 한 토픽에 key로 쓸 때 | 파티셔너를 murmur2로 통일 |
| 파티션 수 변경 | 운영 중 파티션을 늘릴 때 | 넉넉히 잡고 안 바꾼다 |

두 번째도 원리는 같다. `hash(key) % N`에서 N(파티션 수)이 바뀌면 같은 key의 목적지가 바뀐다. 그래서 파티션은 미래 성장까지 보고 넉넉히 잡고, 함부로 늘리지 않는다.

## 실전 규칙

- **한 토픽 = 한 파티셔너.** 그 토픽에 쓰는 모든 프로듀서가 같은 해시를 쓰게 강제한다.
- **언어가 섞이면 murmur2로 통일.** Java가 기준이므로 다른 클라이언트를 맞춘다. kafka-go라면 `&kafka.Murmur2Balancer{}`, librdkafka 계열이라면 `"partitioner": "murmur2_random"`.
- **기본값에 암묵적으로 기대지 않는다.** 파티셔너를 코드/설정에 명시하고, 그 설정이 실제로 먹는지 검증한다.
- **파티션 수는 넉넉히.** 늘리는 순간 key 매핑이 흔들린다.

## 그래서 무서워해야 하나

무조건은 아니다. 이 함정은 세 조건이 동시에 맞아야 물린다. (1) 한 토픽에 (2) 여러 언어 클라이언트가 (3) key 기반 순서·조인에 의존. 단일 언어로 통일했거나 토픽마다 프로듀서가 하나면 만날 일이 없다.

다만 터질 때는 예외도, 로그도 없이 조용히 데이터가 어긋난다. 그래서 규칙을 미리 아는 값이 크다. 예방은 "파티셔너를 명시하고 통일한다" 한 줄이면 끝난다.

---

참고: [Confluent — Standardized Hashing](https://www.confluent.io/blog/standardized-hashing-across-java-and-non-java-producers/) · [Bill Bejeck — A Critical Detail about Kafka Partitioners](https://bbejeck.medium.com/a-critical-detail-about-kafka-partitioners-8e17dfd45a7) · [kafka-go balancer.go](https://github.com/segmentio/kafka-go/blob/main/balancer.go)

---
layout: single
title: "Redis로 메시지 큐를 구현할 수 있을까"
date: 2026-01-24 16:00:00 +0900
categories: [backend, redis]
---

Redis를 메시지 브로커로 쓸 수 있지만, Kafka와는 다르다. "가볍게 알림 보내기"와 "신뢰성 있는 큐/스트림"은 전혀 다른 문제다. 요구사항에 따라 Pub/Sub, List 큐, Streams 중 적합한 모델이 달라지므로, 각 모델의 특성과 한계를 정확히 파악해야 한다.

## 먼저 생각해볼 것

> - 메시지가 유실되면 안 되는가, 유실되어도 괜찮은가?
> - 소비자가 항상 연결되어 있는가, 나중에 소비할 수 있어야 하는가?
> - 여러 소비자가 같은 메시지를 받아야 하는가? (fan-out)
> - 소비 실패 시 재시도가 필요한가?

## 왜 메시지 브로커가 필요한가

메시지 브로커의 핵심 역할은 다음과 같다:

- 생산자와 소비자를 **시간·속도·장애**로부터 분리
- 메시지를 **쌓아 두고** 나중에 처리
- 두 가지 모델:
  - **메시징 큐**: 소비하면 사라짐. 재시도/우선순위 큐에 초점
  - **이벤트 스트림**: 로그처럼 **보존**하며 여러 소비자가 각자 offset 관리

## Redis의 세 가지 전송 모델

### 1. Pub/Sub -- 일회성 fan-out

```redis
PUBLISH notice "deploying at 10:00"
SUBSCRIBE notice
PSUBSCRIBE mail-*   # 패턴 구독
```

| 특징 | 설명 |
|------|------|
| 저장 | **안 함** |
| 수신 조건 | 구독자가 연결돼 있어야 |
| ACK/재전송 | 없음 |
| 사용 시점 | 푸시 알림, 실시간 UI 갱신 등 "잃어도 괜찮은" 신호 |

**주의**: `client-output-buffer-limit pubsub` 초과 시 연결 끊김. 메시지 크기를 작게 유지해야 한다.

### 2. List 기반 큐 -- 단순 작업 큐

```redis
# 생산자
LPUSH jobs "email:123"

# 소비자 (FIFO)
BRPOPLPUSH jobs processing 0   # jobs → processing으로 원자적 이동
# ...작업 처리...
LREM processing 1 "email:123"  # 처리 완료 후 삭제
```

**신뢰성 패턴**:
1. `BRPOPLPUSH`로 processing 리스트에 이동
2. 작업 성공 시 `LREM`으로 삭제
3. 실패 시 processing 리스트 스캔해 재처리

| 특징 | 설명 |
|------|------|
| 저장 | 개발자가 직접 관리 |
| 사용 시점 | 소규모 워커, 간단한 비동기 처리 |
| 한계 | ordering/재시도 정책 직접 구현 필요 |

### 3. Streams -- 보존형, consumer group 지원

Streams는 Redis에서 가장 강력한 메시징 모델이다.

```redis
# 메시지 추가
XADD notifications * type email user 42

# 그룹 생성
XGROUP CREATE notifications senders $ MKSTREAM

# 소비
XREADGROUP GROUP senders worker-1 COUNT 10 STREAMS notifications >

# ACK
XACK notifications senders 1700000000000-0

# 보관 한도 설정
XTRIM notifications MAXLEN ~ 100000
```

| 특징 | 설명 |
|------|------|
| 구조 | append-only 로그, 메시지 ID(시간 기반) + 필드 셋 |
| 신뢰성 | at-least-once |
| 장애 복구 | `XPENDING`/`XAUTOCLAIM`으로 죽은 소비자 메시지 재처리 |
| 사용 시점 | 단일 Redis에서 "작은 카프카 느낌" |

## 어떤 모델을 골라야 할까

| 요구사항 | 추천 모델 |
|----------|----------|
| 푸시 알림, 실시간 피드 (유실 허용) | **Pub/Sub** |
| 간단한 비동기 작업 | **List + BRPOPLPUSH** |
| 백로그/재처리/소비자 그룹 | **Streams** |
| 대규모 데이터 파이프라인 | Kafka/Pulsar 등 전문 브로커 |

## 운영 팁

### Pub/Sub
- **소비자가 생산자보다 빨라야** 한다
- 느린 소비자는 끊기거나 메시지가 유실된다

### List/Streams
- **메시지 크기를 작게** 유지한다
- 소비 지연 모니터링: `XLEN`, `XPENDING`, 리스트 길이

### Streams 특화
- `MAXLEN ~`으로 길이를 제한한다
- 백업/보존 기간을 명시한다

### 클러스터
- Redis 7+ **shared pub/sub** 모드로 불필요한 브로드캐스트를 줄일 수 있다

## 명령 요약

| 모델 | 주요 명령 |
|------|----------|
| **Pub/Sub** | `PUBLISH`, `SUBSCRIBE`, `PSUBSCRIBE` |
| **List 큐** | `LPUSH`, `BRPOP`, `BRPOPLPUSH`, `LMOVE` |
| **Streams** | `XADD`, `XREAD`, `XREADGROUP`, `XACK`, `XPENDING`, `XAUTOCLAIM`, `XTRIM` |

## 정리

```
신뢰성 필요 없음 ──────────────────────────────► 신뢰성 필요
     │                                              │
  Pub/Sub ────────► List 큐 ────────► Streams ────► Kafka
```

Redis는 가벼운 메시징에 적합하지만, 대규모 파이프라인이나 정확한 파티셔닝이 필요하면 전문 브로커를 고려해야 한다.

---

## Consumer Lag 모니터링 (Streams)

```redis
XINFO GROUPS notifications
```

```
1) "name" → "senders"
   "consumers" → 3
   "pending" → 150       # 처리 중인 메시지
   "last-delivered-id" → "1700000000000-0"
   "lag" → 500           # 밀린 메시지 수
```

`lag`이 증가하면 소비자가 처리 속도를 따라가지 못하는 것이다.

**알림 기준**: lag > 1000이면 소비자 추가를 검토한다.

---

## 재시도 전략 (Exponential Backoff)

```python
import time

def process_with_retry(message, max_retries=5):
    for attempt in range(max_retries):
        try:
            process(message)
            return True
        except Exception:
            wait = min(2 ** attempt, 60)  # 1, 2, 4, 8, 16, 32, 60초
            time.sleep(wait)
    return False  # 최대 재시도 초과 → DLQ로
```

Streams에서 실패한 메시지는 `XPENDING`에 남아있다가 `XAUTOCLAIM`으로 다른 소비자가 가져갈 수 있다.

```redis
# 5분 이상 처리 안 된 메시지를 worker-2가 가져감
XAUTOCLAIM notifications senders worker-2 300000 0-0 COUNT 10
```

---

## 자가 체크

> - 메시지 유실이 허용되는가? 허용되면 Pub/Sub, 아니면 Streams
> - 소비자가 죽었을 때 메시지를 재처리할 방법이 있는가?
> - Streams를 쓴다면 `XTRIM`으로 길이를 제한하고 있는가?
> - 대규모라면 Redis 대신 Kafka를 검토했는가?

---

## 참고자료

- [Redis Pub/Sub](https://redis.io/docs/latest/develop/interact/pubsub/)
- [Redis Streams](https://redis.io/docs/latest/develop/data-types/streams/)
- [Redis Streams Tutorial](https://redis.io/docs/latest/develop/data-types/streams/tutorial/)
- [Redis - XAUTOCLAIM](https://redis.io/docs/latest/commands/xautoclaim/)

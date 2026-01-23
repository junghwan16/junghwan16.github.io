---
layout: post
title: "Redis와 캐시 전략 완벽 가이드"
date: 2026-01-23 19:00:00 +0900
categories: [backend, redis]
---

백엔드 시스템에서 성능 최적화를 이야기할 때 캐시는 빠지지 않는 주제입니다. 이 글에서는 캐시의 기본 개념부터 Redis를 활용한 다양한 캐싱 전략, 그리고 실무에서 마주치는 문제들과 해결 방법까지 정리해보겠습니다.

## 1. 캐시란?

캐시(Cache)는 데이터를 미리 복사해두는 임시 저장소입니다. 원본 데이터 저장소보다 빠른 접근 속도를 제공하여 전체 시스템의 성능을 향상시킵니다.

### 캐시 도입이 효과적인 경우

| 상황 | 설명 |
|------|------|
| 느린 응답 속도 | DB 조회에 시간이 오래 걸리는 경우 |
| 반복적인 연산 | 동일한 결과를 반복 계산해야 하는 경우 |
| 불변 데이터 | 자주 변경되지 않는 데이터 |
| 빈번한 요청 | 특정 데이터에 대한 요청이 매우 많은 경우 |

## 2. 왜 Redis인가?

Redis가 캐시 솔루션으로 널리 사용되는 이유:

- **단순한 Key-Value 구조**: 직관적인 데이터 저장과 조회
- **인메모리 저장**: 디스크 기반 DB보다 월등히 빠른 속도
- **다양한 자료구조**: String, List, Hash, Set, Sorted Set 등 지원
- **고가용성**: Sentinel, Cluster를 통한 자동 장애 복구
- **쉬운 확장**: 클러스터 기반 수평 확장

## 3. 캐싱 전략

### 3.1 읽기 전략: Cache-Aside (Look-Aside)

가장 널리 사용되는 패턴입니다. 애플리케이션이 캐시를 "옆에 두고" 필요할 때만 사용합니다.

```
요청 → 캐시 확인 → Hit? → 반환
                  ↓ Miss
            DB 조회 → 캐시 저장 → 반환
```

```python
import redis
import json

cache = redis.Redis()

def get_user(user_id: str) -> dict:
    cache_key = f"user:{user_id}"

    # 1. 캐시 조회
    cached = cache.get(cache_key)
    if cached:
        return json.loads(cached)

    # 2. 캐시 미스 - DB 조회
    user = get_user_from_db(user_id)

    # 3. 캐시에 저장 (TTL 60초)
    if user:
        cache.set(cache_key, json.dumps(user), ex=60)

    return user
```

**장점**: 캐시 장애 시에도 DB 조회로 서비스 유지 가능

**캐시 워밍(Cache Warming)**: 시스템 시작 시 자주 사용될 데이터를 미리 캐시에 채워두는 작업

### 3.2 쓰기 전략

#### Write-Through (동시 쓰기)

DB와 캐시에 동시에 업데이트합니다.

```python
def update_user(user_id: str, data: dict) -> dict:
    # 1. DB 저장
    updated = update_user_in_db(user_id, data)

    # 2. 캐시에도 저장
    if updated:
        cache.set(f"user:{user_id}", json.dumps(updated), ex=60)

    return updated
```

- **장점**: 캐시가 항상 최신 데이터 유지
- **단점**: 쓰기 지연 시간 증가

#### Cache Invalidation (캐시 무효화)

DB 업데이트 시 캐시 데이터를 삭제합니다.

```python
def update_user(user_id: str, data: dict) -> dict:
    # 1. DB 업데이트
    updated = update_user_in_db(user_id, data)

    # 2. 캐시 삭제
    cache.delete(f"user:{user_id}")

    return updated
```

- **장점**: 쓰기가 빠름 (삭제는 저장보다 가벼움)
- **단점**: 업데이트 후 첫 읽기 시 캐시 미스 발생

#### Write-Behind (Write-Back)

쓰기가 매우 빈번한 서비스에 적합합니다. 캐시에만 먼저 쓰고, 비동기로 DB에 반영합니다.

```python
def update_likes(video_id: str) -> int:
    cache_key = f"video:{video_id}:likes"

    # 1. 캐시에 즉시 반영
    current = cache.incr(cache_key)

    # 2. 특정 조건에서 DB 업데이트 예약
    if current % 100 == 0:
        schedule_db_update(video_id, current)

    return current
```

- **장점**: 쓰기가 매우 빠름, DB 부하 감소
- **단점**: 캐시 장애 시 데이터 유실 위험

## 4. 캐시 운영 시 고려사항

### 4.1 메모리 관리

**TTL (Time To Live)**: 데이터 만료 시간 설정

```bash
SET user:123 "data" EX 60  # 60초 후 만료
```

**maxmemory-policy**: 메모리 한도 도달 시 삭제 정책

| 정책 | 설명 |
|------|------|
| `noeviction` | 추가 저장 차단, 에러 반환 (기본값) |
| `allkeys-lru` | LRU 방식으로 삭제 **(캐시 용도로 권장)** |
| `volatile-ttl` | TTL이 설정된 키 중 수명이 짧은 것부터 삭제 |

### 4.2 Cache Stampede (Thundering Herd)

인기 있는 캐시 데이터가 만료되는 순간, 수많은 요청이 동시에 DB로 몰리는 현상입니다.

#### 해결책 1: Mutex Lock

한 번에 하나의 요청만 DB에 접근하도록 락을 겁니다.

```python
def get_data_with_lock(key: str):
    data = cache.get(key)
    if data:
        return data

    lock_key = f"{key}:lock"

    # SETNX로 락 획득 시도
    if cache.set(lock_key, "1", nx=True, ex=10):
        try:
            data = get_from_db(key)
            cache.set(key, data, ex=300)
            return data
        finally:
            cache.delete(lock_key)
    else:
        # 락 획득 실패 - 대기 후 재시도
        time.sleep(0.1)
        return get_data_with_lock(key)
```

#### 해결책 2: 만료 시간 분산 (Jitter)

TTL에 무작위 시간을 더해 만료 시점을 분산시킵니다.

```python
import random

base_ttl = 300
jitter = random.randint(0, 60)
cache.set(key, data, ex=base_ttl + jitter)
```

#### 해결책 3: 백그라운드 갱신

만료 전에 미리 데이터를 갱신합니다. TTL 60초인 데이터가 55초 시점에 요청되면, 기존 데이터를 반환하면서 비동기로 갱신 작업을 시작합니다.

#### 해결책 4: 확률적 조기 재계산 (PER)

남은 TTL을 확인하고 확률적으로 미리 갱신할지 결정합니다. 만료에 가까울수록 갱신 확률이 높아집니다.

```python
import math
import random

BETA = 1.0

def should_recompute(fetch_time: float, ttl: int) -> bool:
    elapsed = time.time() - fetch_time
    prob = elapsed * -BETA * math.log(random.random()) / ttl
    return prob >= 1.0
```

### 4.3 Cache Penetration

존재하지 않는 데이터에 대한 반복 요청으로 DB에 불필요한 부하가 발생하는 문제입니다.

#### 해결책: Null 값 캐싱

```python
def get_data(key: str):
    data = cache.get(key)

    if data is not None:
        return None if data == b"NULL" else json.loads(data)

    db_data = get_from_db(key)

    if db_data:
        cache.set(key, json.dumps(db_data), ex=300)
    else:
        # 없는 데이터도 짧은 TTL로 캐싱
        cache.set(key, "NULL", ex=5)

    return db_data
```

## 5. 정리

| 전략 | 사용 시점 |
|------|----------|
| Cache-Aside | 범용적인 읽기 캐싱 |
| Write-Through | 데이터 일관성이 중요할 때 |
| Cache Invalidation | 쓰기 성능이 중요할 때 |
| Write-Behind | 쓰기가 매우 빈번할 때 |

| 문제 | 해결책 |
|------|--------|
| Cache Stampede | Mutex Lock, TTL Jitter, PER |
| Cache Penetration | Null 값 캐싱 |

캐시는 적절히 사용하면 시스템 성능을 크게 향상시키지만, 데이터 일관성과 장애 상황을 항상 고려해야 합니다. 서비스 특성에 맞는 전략을 선택하는 것이 중요합니다.

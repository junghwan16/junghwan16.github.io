---
layout: single
title: "좋아요 기능, 어떻게 구현해야 빠를까"
date: 2026-01-24 11:00:00 +0900
categories: [backend, redis]
---

뉴스 댓글에 좋아요 기능을 추가한다고 가정해보자. 실시간 트래픽이 많은 사이트라면 1초에 수만 개의 좋아요가 발생할 수 있다. RDB만으로 충분할까?

## 접근 1: RDB로 처리하기

### 단순한 구현과 동시성 문제

가장 직관적인 방법은 다음과 같다:

```sql
UPDATE comment SET like_count = like_count + 1 WHERE id = ?;
```

이 쿼리는 간단하지만, 트래픽이 많으면 심각한 **락 경합(Lock Contention)** 문제를 일으킨다.

### InnoDB의 잠금 메커니즘

`UPDATE` 쿼리 실행 시 내부 동작은 다음과 같다:

1. 트랜잭션 시작
2. `id = ?` 조건에 해당하는 레코드 검색
3. 해당 레코드에 **배타적 잠금(X-Lock)** 설정
4. 다른 트랜잭션은 첫 번째 트랜잭션이 커밋될 때까지 대기
5. 값 업데이트 후 커밋, 잠금 해제

### 문제점: 병목 현상

인기 댓글에 초당 수천 개의 좋아요 요청이 몰리면 어떻게 되는지 살펴보자:

```
요청 1: comment_id=123에 X-Lock 획득, 업데이트 중
요청 2: X-Lock 획득 시도 → 대기
요청 3: 대기
요청 4: 대기
...
```

모든 `UPDATE`가 순차 실행되어 처리량이 급격히 떨어진다.

### 해결책 A: 카운터 샤딩 (Counter Sharding)

여러 개의 보조 카운터로 업데이트 요청을 분산시키는 방법이다.

```sql
CREATE TABLE comment_like_counters (
    comment_id BIGINT NOT NULL,
    shard_id TINYINT NOT NULL,  -- 0-99
    count INT NOT NULL DEFAULT 0,
    PRIMARY KEY (comment_id, shard_id)
);
```

**쓰기**: 랜덤 샤드 선택 후 업데이트

```sql
-- shard_id는 애플리케이션에서 랜덤 생성 (e.g., 42)
UPDATE comment_like_counters
SET count = count + 1
WHERE comment_id = ? AND shard_id = 42;
```

락 경합이 1/N (N=샤드 개수)로 줄어든다.

**읽기**: 모든 샤드 합산

```sql
SELECT SUM(count) FROM comment_like_counters WHERE comment_id = ?;
```

### 해결책 B: 쓰기 지연 (Write-back)

요청을 일단 기록해두고 비동기로 RDB에 반영하는 전략이다.

```sql
-- 1. 로그성 테이블에 INSERT만 수행
INSERT INTO likes (comment_id, user_id) VALUES (?, ?);

-- 2. 배치 작업이 주기적으로 집계하여 업데이트
UPDATE comment c
JOIN (
    SELECT comment_id, COUNT(*) as new_likes
    FROM likes
    WHERE created_at > (NOW() - INTERVAL 1 MINUTE)
    GROUP BY comment_id
) AS l ON c.id = l.comment_id
SET c.like_count = c.like_count + l.new_likes;
```

실시간 정확성 대신 **결과적 일관성(Eventual Consistency)**을 갖게 된다.

## 접근 2: Redis로 처리하기

RDB의 락 경합 문제를 근본적으로 피하려면 Redis를 활용할 수 있다.

### 단순 카운팅 (Strings)

```redis
-- 좋아요 수 증가
INCR comment:123:likes_count

-- 좋아요 수 감소
DECR comment:123:likes_count

-- 현재 좋아요 수 조회
GET comment:123:likes_count
```

**장점:**
- 매우 빠름 (밀리초 단위)
- `INCR`, `DECR`은 **원자적(Atomic)** 연산 → 락 경합 없음

**단점:**
- 누가 좋아요를 눌렀는지 알 수 없음
- Redis 재시작 시 데이터 유실 가능 (Persistence 설정에 따라)

### 고유 사용자 카운팅 (Sets)

누가 좋아요를 눌렀는지 추적해야 할 때는 Sets를 사용한다:

```redis
-- 사용자 123이 댓글 456에 좋아요
SADD comment:456:liked_by user:123

-- 좋아요 취소
SREM comment:456:liked_by user:123

-- 좋아요 수 조회 (고유 카운트)
SCARD comment:456:liked_by

-- 특정 사용자가 좋아요를 눌렀는지 확인
SISMEMBER comment:456:liked_by user:123
```

**장점:**
- **고유성 보장**: 중복 좋아요 방지
- **빠른 존재 여부 확인**: `SISMEMBER` O(1)

**단점:**
- 좋아요 수가 많아지면 메모리 사용량 증가
- 좋아요 시각 등 추가 정보 저장 불가

## 접근 3: RDB + Redis 하이브리드

대부분의 실제 서비스에서 사용하는 방식이다.

```
┌─────────────┐     ┌─────────────┐
│   Redis     │     │    RDB      │
│ (실시간)    │     │ (영속성)    │
├─────────────┤     ├─────────────┤
│ likes_count │     │ likes 테이블│
│ liked_by    │     │ (원본 기록) │
└─────────────┘     └─────────────┘
```

- **RDB**: `likes` 테이블로 누가 언제 좋아요를 눌렀는지 원본 기록 저장
- **Redis**: 실시간 카운트 및 사용자 목록 캐싱

### 동기화 전략 1: Read-through

```python
def get_likes_count(comment_id: int) -> int:
    # 1. Redis에서 먼저 조회
    count = redis.get(f"comment:{comment_id}:likes_count")
    if count is not None:
        return int(count)

    # 2. 캐시 미스 → RDB에서 조회
    count = db.query("SELECT COUNT(*) FROM likes WHERE comment_id = ?", comment_id)

    # 3. Redis에 저장
    redis.set(f"comment:{comment_id}:likes_count", count, ex=300)
    return count
```

### 동기화 전략 2: Write-back (권장)

```python
def add_like(comment_id: int, user_id: int):
    # 1. Redis 즉시 업데이트
    redis.sadd(f"comment:{comment_id}:liked_by", user_id)
    redis.incr(f"comment:{comment_id}:likes_count")

    # 2. RDB에 INSERT (비동기 가능)
    db.execute("INSERT INTO likes (comment_id, user_id) VALUES (?, ?)",
               comment_id, user_id)

    # 3. RDB의 like_count는 배치 작업으로 주기적 갱신
```

Redis는 항상 최신 실시간 카운트를 제공하고, RDB의 `like_count`는 결과적 일관성을 갖는다.

## 고려사항

### Redis Persistence

`RDB 스냅샷`이나 `AOF` 설정으로 데이터 유실을 방지할 수 있다.

### 메모리 관리

- 키 설계를 간결하게 (`comment:{id}:likes_count`)
- 적절한 TTL 설정
- 필요시 Redis Cluster로 분산

### 데이터 불일치 처리

Redis 업데이트 성공, RDB 실패 시나리오를 위한:
- 재시도 로직
- 데드 레터 큐(DLQ)
- 데이터 정합성 검증 배치 작업

## 정리

| 접근 방식 | 장점 | 단점 | 추천 시나리오 |
|-----------|------|------|---------------|
| **RDB 단독** | ACID 보장, 추가 인프라 불필요 | 락 경합, 성능 저하 | 트래픽 적은 서비스 |
| **Redis 단독** | 빠른 속도, 락 경합 없음 | 영속성 설정 필요, 데이터 유실 가능 | 임시 데이터, 실시간 성능 최우선 |
| **하이브리드** | 성능 + 안정성 | 아키텍처 복잡, 불일치 가능 | **대부분의 상용 서비스** |

결론적으로, 대부분의 서비스는 **RDB와 Redis를 조합한 하이브리드 아키텍처**로 빠른 응답 속도와 데이터 신뢰성을 모두 확보한다.

---

## 카운팅 자료구조 선택 가이드

좋아요 외에도 카운팅은 요구사항에 따라 완전히 다른 자료구조가 필요하다.

### 패턴별 비교

| 패턴 | 자료구조 | 정확도 | 랭킹 | 유니크 | 메모리 |
|------|----------|--------|------|--------|--------|
| INCR | String | 정확 | X | X | 낮음 |
| HINCRBY | Hash | 정확 | X | X | 중간 |
| ZINCRBY | Sorted Set | 정확 | O | X | 높음 |
| Bitmap | Bitmap | 정확 | X | O | 낮음 |
| HyperLogLog | HLL | 근사 | X | O | 매우 낮음 |

### HyperLogLog: 대규모 유니크 카운팅

DAU처럼 정확한 숫자보다 추세가 중요한 경우 HyperLogLog가 압도적으로 유리하다:

```redis
PFADD dau:2026-01-19 user:1001 user:1002
PFCOUNT dau:2026-01-19
PFMERGE dau:week dau:2026-01-19 dau:2026-01-20  # 주간 합산
```

100만 유저 유니크 카운트 시 메모리 비교:

| 자료구조 | 메모리 |
|----------|--------|
| Set | ~50MB |
| HyperLogLog | **12KB** (고정) |

오차 약 0.81%를 허용하면 메모리를 4,000배 이상 절약할 수 있다.

### Bitmap: 출석/접속 같은 이진 상태

userId를 비트 오프셋으로 매핑하면 메모리 효율적으로 boolean 집계가 가능하다:

```redis
SETBIT attend:2026-01-19 1001 1   # userId=1001 출석
BITCOUNT attend:2026-01-19         # 출석자 수
```

### 시나리오별 추천

| 시나리오 | 추천 패턴 |
|----------|----------|
| 좋아요 수 (중복 허용) | String + INCR |
| 좋아요 수 (중복 제거) | Set + SCARD |
| 리더보드 | Sorted Set + ZINCRBY |
| 일별 활성 사용자 (DAU) | HyperLogLog |
| 출석 체크 | Bitmap |
| API 레이트 리밋 | ZSET 타임스탬프 |

---

## 카운터 샤딩: 샤드 개수 선택

| 동시 요청/초 | 권장 샤드 수 |
|-------------|-------------|
| 100 이하 | 샤딩 불필요 |
| 100~1,000 | 10개 |
| 1,000~10,000 | 100개 |
| 10,000+ | 1,000개 또는 Redis 전환 |

**계산 기준**: 단일 레코드 락 처리량 ~100 TPS. 샤드 N개면 N x 100 TPS 가능.

---

## Redis 장애 시 폴백

```python
def get_likes_count(comment_id: int) -> int:
    try:
        count = redis.get(f"comment:{comment_id}:likes_count")
        if count is not None:
            return int(count)
    except RedisError:
        pass  # Redis 장애 시 RDB 폴백

    # RDB에서 조회
    count = db.query("SELECT like_count FROM comment WHERE id = ?", comment_id)
    return count or 0
```

Redis 장애가 좋아요 조회를 막으면 안 된다. 폴백으로 RDB 조회.

---

## 참고자료

- [Redis - INCR](https://redis.io/docs/latest/commands/incr/)
- [Redis - Sets](https://redis.io/docs/latest/develop/data-types/sets/)
- [MySQL - InnoDB Locking](https://dev.mysql.com/doc/refman/8.0/en/innodb-locking.html)
- [Instagram Engineering - Storing Hundreds of Millions of Simple Key-Value Pairs in Redis](https://instagram-engineering.com/storing-hundreds-of-millions-of-simple-key-value-pairs-in-redis-1091ae80f74c)

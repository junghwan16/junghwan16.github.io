---
title: "좋아요 카운터를 RDB에 바로 올리면 생기는 일"
url: "/backend/redis/2026/01/24/redis-likes-implementation/"
date: 2026-01-24 11:00:00 +0900
categories: [backend, redis]
---

좋아요 수는 `like_count = like_count + 1`이면 끝날 것처럼 보인다. 트래픽이 적을 때는 맞다. 하지만 인기 댓글 하나에 요청이 몰리면 그 row는 카운터가 아니라 락 대기열이 된다.

## RDB 카운터의 병목

가장 단순한 구현은 이렇다.

```sql
UPDATE comment
SET like_count = like_count + 1
WHERE id = ?;
```

InnoDB는 해당 row에 배타 락을 잡고 값을 바꾼다. 같은 댓글에 좋아요가 몰리면 모든 요청이 같은 row의 락을 기다린다.

```text
요청 1: comment_id=123 row lock 획득
요청 2: 대기
요청 3: 대기
요청 4: 대기
```

문제는 RDB가 느리다는 것이 아니라, 쓰기 대상이 하나라 병렬화가 안 된다는 점이다.

## 선택지는 세 가지다

| 방식 | 장점 | 단점 | 맞는 경우 |
|---|---|---|---|
| RDB 단독 | 단순하고 정합성이 명확함 | 인기 row에서 락 경합 | 트래픽이 작거나 정확성이 우선 |
| RDB 카운터 샤딩 | DB 안에서 경합 완화 | 읽을 때 합산 필요 | Redis 없이 버텨야 할 때 |
| Redis + RDB | 빠른 실시간 카운트와 영속 기록 분리 | 동기화 설계 필요 | 대부분의 고트래픽 좋아요 |

카운터 샤딩은 row를 여러 개로 쪼개 쓰기를 분산한다.

```sql
CREATE TABLE comment_like_counter (
    comment_id BIGINT NOT NULL,
    shard_id TINYINT NOT NULL,
    count BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (comment_id, shard_id)
);
```

쓰기 때는 랜덤 shard를 올리고, 읽기 때는 합산한다. 락 경합은 줄지만 읽기와 운영이 복잡해진다.

## Redis는 경합을 밖으로 뺀다

Redis의 `INCR`은 단일 키에 대한 원자적 연산이다.

```redis
INCR comment:123:likes_count
DECR comment:123:likes_count
GET comment:123:likes_count
```

단순 카운트만 필요하면 이걸로 충분하다. 하지만 "한 유저가 한 번만 좋아요"를 보장해야 하면 Set이 필요하다.

```redis
SADD comment:123:liked_by user:456
SREM comment:123:liked_by user:456
SCARD comment:123:liked_by
SISMEMBER comment:123:liked_by user:456
```

`SADD`가 새로 추가했을 때만 카운트를 올려야 하므로, 실제 구현에서는 `SADD`와 `INCR`을 Lua나 transaction으로 묶는다.

```lua
-- KEYS[1] = liked_by set
-- KEYS[2] = count key
-- ARGV[1] = user id
local added = redis.call("SADD", KEYS[1], ARGV[1])
if added == 1 then
  return redis.call("INCR", KEYS[2])
end
return redis.call("GET", KEYS[2])
```

## 원본 기록은 RDB에 둔다

Redis만 믿으면 장애 복구와 감사가 어렵다. 보통은 RDB에 원본 이벤트를 남기고, Redis는 실시간 조회용으로 둔다.

```text
write path:
  1. likes 테이블에 INSERT 또는 DELETE
  2. Redis set/count 갱신

read path:
  1. Redis count 조회
  2. miss 또는 장애 시 RDB 집계값으로 폴백
```

RDB의 `like_count` 컬럼은 배치로 맞추거나, 원본 `likes` 테이블에서 다시 계산할 수 있게 둔다. 중요한 것은 Redis의 카운트가 틀어졌을 때 복구할 기준이 있어야 한다는 점이다.

## 결정 기준

좋아요가 핵심 지표이고 인기 객체에 쓰기가 몰린다면 RDB row 하나에 직접 `UPDATE`하는 구조는 오래 버티기 어렵다. Redis로 실시간 경합을 빼고, RDB에는 원본 기록을 남긴다.

반대로 트래픽이 작고 정확한 트랜잭션 경계가 더 중요하다면 RDB 단독이 낫다. Redis를 넣는 순간 장애 처리, 복구, 캐시 불일치, 메모리 관리가 따라온다.

좋아요 카운터의 설계 질문은 "어떤 자료구조가 빠른가"가 아니다. **정확한 원본은 어디에 남기고, 빠른 숫자는 어디서 읽을 것인가**다.

## 참고자료

- [Redis INCR](https://redis.io/docs/latest/commands/incr/)
- [Redis Sets](https://redis.io/docs/latest/develop/data-types/sets/)
- [MySQL InnoDB Locking](https://dev.mysql.com/doc/refman/8.0/en/innodb-locking.html)

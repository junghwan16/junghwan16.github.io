---
layout: post
title: "Redis 자료구조, 언제 어떤 걸 써야 할까"
date: 2026-01-24 09:00:00 +0900
categories: [backend, redis]
---

Redis는 단순한 키-값 스토어가 아닙니다. 다양한 자료구조를 지원하고, 각각이 특정 문제를 효율적으로 해결합니다. 자료구조 선택이 곧 설계입니다.

## 먼저 생각해볼 것

> - 저장하려는 데이터의 형태는 무엇인가? (단일 값, 목록, 집합, 순위?)
> - 어떤 연산이 가장 빈번한가? (조회, 삽입, 삭제, 범위 조회?)
> - 중복을 허용하는가? 순서가 중요한가?
> - 대략적인 데이터 크기는? (메모리 제약)

## 자료구조 한눈에 보기

| 자료구조 | 핵심 특징 | 대표 사용 사례 |
|----------|----------|---------------|
| **String** | 단일 값 (최대 512MB) | 캐시, 카운터, 토큰 |
| **List** | 순서 있는 연결 리스트 | 큐, 최근 항목 |
| **Set** | 중복 없는 집합 | 태그, 공통 친구 |
| **Sorted Set** | 점수로 정렬된 집합 | 랭킹, 최근순 |
| **Hash** | 필드-값 맵 | 객체 저장 |
| **Bitmap** | 비트 배열 | 출석 체크, 플래그 |
| **HyperLogLog** | 고유 카운트 (근사) | DAU 추정 |
| **Stream** | append-only 로그 | 메시지 큐 |

## String

가장 기본적인 자료구조. 숫자도 문자열로 저장하지만 원자적 증감이 가능합니다.

```redis
SET user:123:name "Alice"
GET user:123:name

# 원자적 카운터
SET counter 100
INCR counter        # 101
INCRBY counter 10   # 111

# 키가 없을 때만 저장 (분산 락, 멱등 처리)
SET lock:order:456 "worker-1" NX EX 30
```

### 자가 체크

> - 여러 키를 조회할 때 `MGET`을 쓰고 있는가? (round-trip 감소)
> - 카운터에 `INCR`을 쓰면 락 없이 원자적 증가가 가능하다

## List

양쪽 끝에서 push/pop이 가능한 연결 리스트입니다.

```redis
# FIFO 큐
RPUSH jobs "task:1"
RPUSH jobs "task:2"
BLPOP jobs 0        # 블로킹 pop

# 최근 N개 유지
LPUSH recent:user:123 "item:1"
LTRIM recent:user:123 0 9    # 최근 10개만 유지
```

### 주요 명령어

| 명령어 | 설명 |
|--------|------|
| `LPUSH/RPUSH` | 왼쪽/오른쪽에 삽입 |
| `LPOP/RPOP` | 왼쪽/오른쪽에서 꺼내기 |
| `BLPOP/BRPOP` | 블로킹 pop (작업 큐) |
| `LRANGE` | 범위 조회 |
| `LTRIM` | 범위 외 삭제 (길이 제한) |

### 자가 체크

> - 작업 큐로 쓸 때 `BRPOPLPUSH` 패턴으로 처리 중 데이터를 보존하고 있는가?
> - `LTRIM`으로 무한 증가를 방지하고 있는가?

## Set

중복이 없는 집합. 집합 연산(교집합, 합집합)이 강력합니다.

```redis
SADD tags:post:1 "redis" "backend" "database"
SMEMBERS tags:post:1

# 집합 연산
SINTER user:1:following user:2:following  # 공통 팔로잉
SDIFF user:1:following user:2:following   # 차집합
```

### 자가 체크

> - 멤버십 확인에 `SISMEMBER`를 쓰면 O(1)이다
> - 큰 Set에 `SMEMBERS`를 쓰면 모든 요소를 반환하므로 주의

## Sorted Set (ZSET)

점수(score)로 자동 정렬되는 집합입니다. 랭킹, 최근순 정렬에 최적.

```redis
# 리더보드
ZINCRBY leaderboard 10 "user:1"
ZREVRANGE leaderboard 0 9 WITHSCORES  # 상위 10명

# 최근 검색 (score = timestamp)
ZADD recent:user:123 1706123456 "검색어"
ZREVRANGE recent:user:123 0 19        # 최근 20개
```

### 자가 체크

> - 같은 member를 `ZADD`하면 score만 업데이트된다 (중복 자동 제거)
> - 범위 삭제는 `ZREMRANGEBYRANK`나 `ZREMRANGEBYSCORE`로

## Hash

작은 객체를 필드 단위로 저장합니다.

```redis
HSET user:123 name "Alice" age 30 city "Seoul"
HGET user:123 name
HGETALL user:123

# 필드 단위 증가
HINCRBY user:123 login_count 1
```

### 자가 체크

> - 너무 많은 필드를 가진 Hash는 리밸런싱 시 블로킹을 유발할 수 있다
> - 개별 필드 TTL은 불가. 키 전체에만 TTL 설정 가능

## Bitmap

비트 단위 조작. 출석 체크, 플래그 관리에 메모리 효율적입니다.

```redis
# userId를 오프셋으로 출석 체크
SETBIT attend:2026-01-24 1001 1
SETBIT attend:2026-01-24 1002 1
BITCOUNT attend:2026-01-24      # 출석자 수
```

### 자가 체크

> - userId가 오프셋이 되므로, userId가 크면 메모리가 커질 수 있다
> - 날짜별 키로 분리하고 TTL을 설정

## HyperLogLog

고유 값 개수의 근사치. 메모리 12KB 고정, 오차 약 0.81%.

```redis
PFADD dau:2026-01-24 "user:1" "user:2" "user:3"
PFCOUNT dau:2026-01-24

# 여러 날짜 합산
PFMERGE dau:week dau:2026-01-24 dau:2026-01-23 dau:2026-01-22
```

### 자가 체크

> - 정확한 숫자가 필요하면 Set + SCARD를 써야 한다
> - 어떤 member가 있는지는 알 수 없다 (카운트만 가능)

## Stream

append-only 로그. Consumer Group으로 워커 분산 처리.

```redis
XADD notifications * type email user 42
XREADGROUP GROUP workers worker-1 COUNT 10 STREAMS notifications >
XACK notifications workers 1706123456789-0
```

### 자가 체크

> - Kafka처럼 쓰고 싶다면 Stream, 단순 pub/sub은 PUBLISH/SUBSCRIBE
> - `XTRIM`으로 길이를 제한하지 않으면 무한 증가

## 선택 가이드

| 요구사항 | 추천 자료구조 |
|----------|--------------|
| 단순 캐시, 카운터 | String |
| 작업 큐, 최근 항목 | List |
| 중복 없는 태그, 멤버십 | Set |
| 랭킹, 최근순 정렬 | Sorted Set |
| 객체 저장, 필드 단위 조회 | Hash |
| 출석, 플래그 (공간 효율) | Bitmap |
| DAU, UV 추정 | HyperLogLog |
| 메시지 큐, 이벤트 로그 | Stream |

## 자가 체크

> - 자료구조 선택이 성능과 메모리를 결정한다. 요구사항을 먼저 정의했는가?
> - O(N) 명령어(LRANGE, SMEMBERS 등)는 데이터가 커지면 비용이 커진다
> - 클러스터 환경에서 멀티키 연산이 필요하면 해시 태그 `{}`를 사용

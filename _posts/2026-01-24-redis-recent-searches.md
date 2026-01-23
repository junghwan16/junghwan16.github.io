---
layout: post
title: "Redis ZSET으로 최근 검색 기록 구현하기"
date: 2026-01-24 19:00:00 +0900
categories: [backend, redis]
---

최근 검색 기록(Recent Searches) 기능을 Redis ZSET으로 구현하는 방법을 정리합니다. 시스템 설계 면접에서도 자주 나오는 주제입니다.

## 요구사항 정의

| 항목 | 정의 |
|------|------|
| 대상 | 로그인 유저 기준 (`userId` 단위) |
| 노출 | 최근 N개 (예: 20개 노출, 100개 저장) |
| 정렬 | 최신 순 |
| 중복 | 같은 검색어는 하나만 유지, 재검색 시 최신으로 끌어올림 |
| 삭제 | 항목 삭제 / 전체 삭제 지원 |
| 보관 | 키 단위 TTL 90일 (슬라이딩) |

## 왜 ZSET인가?

| 요구사항 | ZSET 해결 방법 |
|----------|---------------|
| 최근순 조회 | `ZREVRANGE` |
| 중복 제거 + 최신화 | 동일 member에 score만 업데이트 |
| N개 제한 | `ZREMRANGEBYRANK`로 오래된 것 제거 |

## 데이터 모델

```
키: recentsearch:{userId}
자료구조: ZSET
  - member: 정규화된 검색어
  - score: 타임스탬프 (ms)
```

## 타임스탬프 충돌 처리

ms 단위는 충돌 가능. 안정적인 정렬을 위해:

```python
score = now_ms * 1000 + (now_ns % 1000)
# 또는
score = now_ms + random.randint(0, 999)
```

## 원자성: Lua 스크립트

동시 요청 시 N 제한이 깨지거나 TTL 갱신 누락 방지:

```lua
-- KEYS[1]: recentsearch:{userId}
-- ARGV: member, score, maxN, ttlSeconds
local key = KEYS[1]
local member = ARGV[1]
local score = tonumber(ARGV[2])
local maxN = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])

redis.call("ZADD", key, score, member)
redis.call("EXPIRE", key, ttl)

local overflow = redis.call("ZCARD", key) - maxN
if overflow > 0 then
  redis.call("ZREMRANGEBYRANK", key, 0, overflow - 1)
end
return 1
```

핵심: `ZADD` + `EXPIRE` + `TRIM`이 **하나의 원자적 연산**

## API 설계

### 조회

```
GET /recent-searches?limit=20
```

```redis
ZREVRANGE recentsearch:{userId} 0 19 WITHSCORES
```

### 개별 삭제

```
DELETE /recent-searches/{query}
```

```redis
ZREM recentsearch:{userId} {query}
```

### 전체 삭제

```
DELETE /recent-searches
```

```redis
DEL recentsearch:{userId}
```

## TTL 정책

### 권장: 키 단위 TTL (슬라이딩)

- 매 검색마다 TTL 90일로 갱신
- 활동 유저 키는 유지, 비활동 유저는 자동 삭제
- 저장 비용 예측 가능, 운영 단순

### 항목별 90일이 필요하면?

```redis
ZREMRANGEBYSCORE key -inf (now-90d)
```

배치 job으로 분리 권장 (모든 write마다 하면 비용 증가)

## 트래픽/성능 계산

### 가정

- DAU 1,000,000
- 검색 5회/유저/일 → 5,000,000 searches/day
- 평균 QPS ≈ 58
- 피크 10배 → ~580 QPS

### 결론

- Redis 단일 클러스터로 충분
- 저장은 best-effort로 비동기 처리
- Redis 장애 시에도 검색 기능은 정상 동작하도록 격리

## 메모리 산정

### 상한 추정

- 활성 유저 100만 × 100개 = 1억 엔트리
- 중복 제거 + TTL로 실제는 훨씬 적음
- 비활동 유저 키는 자동 삭제

### 필요 파라미터

- 평균 검색어 길이 (한글 UTF-8은 3바이트/글자)
- ZSET 엔트리 오버헤드
- 실측 기반으로 조정

## 엣지 케이스 / 보안

| 항목 | 대응 |
|------|------|
| PII | 보관 최소화, TTL, 삭제 기능 필수 |
| 계정 삭제 | 유저 탈퇴 시 키 삭제 |
| 검색어 정규화 | 공백 트림, 대소문자/유니코드 정규화 |
| 악성 입력 | 길이 제한 (예: 100자), rate-limit |

## 정리: 면접 답변

> "최근 검색 기록은 유저별로 최근 N개를 최신순으로 보여주는 기능입니다. 중복 검색어는 하나만 유지하고 재검색 시 최신으로 끌어올립니다.
>
> Redis ZSET을 사용하고 키는 `recentsearch:{userId}`로 둡니다. member는 정규화된 검색어, score는 ms 타임스탬프입니다.
>
> 저장 시 `ZADD` + `EXPIRE` + `ZREMRANGEBYRANK`를 Lua로 원자적으로 묶어 N개 제한과 TTL을 보장합니다.
>
> 조회는 `ZREVRANGE`, 삭제는 `ZREM`/`DEL`입니다.
>
> 검색 저장은 best-effort로 분리해서 Redis 장애가 검색 자체에 영향을 주지 않게 합니다."

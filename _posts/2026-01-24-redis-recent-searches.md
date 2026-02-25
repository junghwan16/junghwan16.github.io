---
title: "최근 검색 기록, Redis로 어떻게 구현할까"
date: 2026-01-24 19:00:00 +0900
categories: [backend, redis]
---

최근 검색 기록은 단순해 보이지만 중복 제거, 최신순 정렬, N개 제한 등 여러 요구사항이 얽혀 있다. 이 복합적인 요구사항을 하나의 자료구조로 깔끔하게 해결하는 것이 핵심이며, 시스템 설계 면접에서도 자주 등장하는 주제다.

## 먼저 생각해볼 것

> - 최근 몇 개를 보여줄 것인가? (노출 N개 vs 저장 M개)
> - 같은 검색어를 다시 검색하면 어떻게 처리하는가?
> - 검색 기록을 얼마나 오래 보관할 것인가?
> - 검색 기록 저장 실패가 검색 자체에 영향을 주면 안 된다

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

요구사항을 하나씩 살펴보면, ZSET이 왜 최적의 선택인지 명확해진다.

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

ms 단위는 충돌 가능하다. 안정적인 정렬을 위해 다음과 같이 처리한다:

```python
score = now_ms * 1000 + (now_ns % 1000)
# 또는
score = now_ms + random.randint(0, 999)
```

## 원자성: Lua 스크립트

동시 요청 시 N 제한이 깨지거나 TTL 갱신이 누락되는 것을 방지해야 한다. Lua 스크립트로 세 연산을 하나로 묶는다:

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

핵심: `ZADD` + `EXPIRE` + `TRIM`이 **하나의 원자적 연산**이다.

## API 설계

각 API의 Redis 명령어 매핑을 살펴보자.

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

배치 job으로 분리하는 것을 권장한다 (모든 write마다 수행하면 비용이 증가한다).

## 트래픽/성능 계산

### 가정

- DAU 1,000,000
- 검색 5회/유저/일 → 5,000,000 searches/day
- 평균 QPS ≈ 58
- 피크 10배 → ~580 QPS

### 결론

- Redis 단일 클러스터로 충분하다
- 저장은 best-effort로 비동기 처리한다
- Redis 장애 시에도 검색 기능은 정상 동작하도록 격리해야 한다

## 메모리 산정

### 상한 추정

- 활성 유저 100만 x 100개 = 1억 엔트리
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

---

## 대규모 성능

ZSET은 내부적으로 skiplist를 사용한다.

| 연산 | 시간 복잡도 | 100개 | 10만 개 |
|------|------------|-------|---------|
| ZADD | O(log N) | 0.01ms | 0.02ms |
| ZREVRANGE 20 | O(log N + M) | 0.01ms | 0.02ms |
| ZREMRANGEBYRANK | O(log N + M) | 0.01ms | 0.02ms |

100개 제한이면 N=100으로 고정되어 성능 걱정 없다.

---

## 검색어 정규화

```python
import unicodedata

def normalize_query(q: str) -> str:
    q = q.strip()
    q = q.lower()
    # 유니코드 정규화 (한글 자모 분리 방지)
    q = unicodedata.normalize("NFC", q)
    # 연속 공백 제거
    q = " ".join(q.split())
    return q[:100]  # 길이 제한

# "  카페   라떼  " → "카페 라떼"
```

정규화 안 하면 "카페라떼"와 "카페 라떼"가 별개로 저장된다.

---

## 자가 체크

> - `ZADD` + `EXPIRE` + `ZREMRANGEBYRANK`를 원자적으로 처리하고 있는가?
> - 검색어를 저장하기 전에 정규화(trim, lowercase 등)하고 있는가?
> - 유저 탈퇴 시 검색 기록 키를 삭제하는 로직이 있는가?
> - Redis 장애 시에도 검색 기능이 정상 동작하도록 격리되어 있는가?

---

## 참고자료

- [Redis - Sorted Sets](https://redis.io/docs/latest/develop/data-types/sorted-sets/)
- [Redis - ZADD](https://redis.io/docs/latest/commands/zadd/)
- [Redis - Lua Scripting](https://redis.io/docs/latest/develop/interact/programmability/eval-intro/)

---
layout: post
title: "Redis로 카운팅할 때, 어떤 자료구조를 써야 할까"
date: 2026-01-24 17:00:00 +0900
categories: [backend, redis]
---

카운팅은 단순해 보이지만, 요구사항에 따라 완전히 다른 접근이 필요합니다. "조회수 1 올리기"와 "고유 방문자 수 세기"는 전혀 다른 문제입니다.

## 먼저 생각해볼 것

> - 정확한 숫자가 필요한가, 근사치로 충분한가?
> - 같은 사용자가 여러 번 세면 안 되는가? (중복 제거)
> - 상위 N개 랭킹이 필요한가?
> - 일별/주별 등 시간 단위로 리셋이 필요한가?

## 선택 기준

| 질문 | 고려사항 |
|------|----------|
| 정확 vs 근사? | 과금/정산 → 정확, DAU/UV 모니터링 → 근사 가능 |
| 범위는? | 전체 합계만? 키별/사용자별 분포? |
| 순서/랭킹? | 단순 합? 상위 N 필요? |
| TTL? | 하루/주 단위 자동 만료? |
| 중복 제거? | 같은 주체가 여러 번 세면 1로? |

## 패턴 1: String + INCR (정확, 전역 카운트)

가장 단순한 전역 카운터. 원자적이며 빠릅니다.

```redis
INCR page:view:2026-01-19
INCRBY orders:total 5
```

- 일자 단위 키 + TTL → 자동 롤업
- 리밸런싱 이슈 적음

## 패턴 2: Hash + HINCRBY (정확, 그룹별 카운트)

한 키 안에서 여러 필드의 카운트 관리:

```redis
HINCRBY likes:post:42 user:1001 1
HINCRBY status:count posted 1
```

- 필드가 많아지면 주기적 클린업 또는 샤딩 고려
- `HINCRBYFLOAT`로 실수도 증가 가능

## 패턴 3: Sorted Set + ZINCRBY (정확, 상위 N/랭킹)

점수를 증가시키며 상위 N을 뽑을 때:

```redis
ZINCRBY leaderboard:2026 10 user:1001
ZREVRANGE leaderboard:2026 0 9 WITHSCORES
```

- score는 누적 합계
- 주/월별 키로 분리 권장

## 패턴 4: Bitmap (정확, boolean 집계)

출석/접속 같은 이진 상태를 메모리 효율적으로:

```redis
SETBIT attend:2026-01-19 1001 1   # userId=1001 출석
BITCOUNT attend:2026-01-19         # 출석자 수
```

- userId를 비트 오프셋으로 매핑할 때 유용
- `BITFIELD`로 작은 정수 카운터 배열도 가능

## 패턴 5: HyperLogLog (근사, 유니크 카운트)

고유 사용자/아이템 수를 저메모리로 추정:

```redis
PFADD dau:2026-01-19 user:1001 user:1002
PFCOUNT dau:2026-01-19
```

- 오차 약 **0.81%**
- 순위/멤버 목록은 알 수 없음
- `PFMERGE`로 여러 키 합산 (주간/월간 UV)

## 패턴 6: Sliding Window / 시간대별 카운팅

### 키 분할 방식

```redis
# 분(minute) 단위 키, TTL 1시간
SET hits:2026-01-19-14-30 100 EX 3600
```

최근 1시간 합계를 합산

### ZSET 타임스탬프 방식

```redis
ZADD hits now_ms member
ZREMRANGEBYSCORE hits 0 (now-1h)   # 창(window) 유지
ZCARD hits                          # 개수 집계
```

API 레이트 리밋, 최근 활동 감지에 사용

## 패턴 7: 멱등/중복 제거 카운팅

요청 ID로 중복 방어:

```redis
SETNX req:123 1
EXPIRE req:123 3600
# 성공 시에만 카운팅
HINCRBY stats:post:42 view 1
```

Kafka 등에서 재처리 가능한 이벤트일 때 유용

## 패턴별 비교

| 패턴 | 자료구조 | 정확도 | 랭킹 | 유니크 | 메모리 |
|------|----------|--------|------|--------|--------|
| INCR | String | 정확 | X | X | 낮음 |
| HINCRBY | Hash | 정확 | X | X | 중간 |
| ZINCRBY | Sorted Set | 정확 | O | X | 높음 |
| Bitmap | Bitmap | 정확 | X | O | 낮음 |
| HyperLogLog | HLL | 근사 | X | O | 매우 낮음 |

## 운영 팁

### 대형 키 청소

```redis
SCAN 0 MATCH counter:* COUNT 1000
# 주기적 DEL 또는 HDEL/ZREMRANGEBYRANK
```

### 클러스터 멀티키 연산

해시 태그로 같은 슬롯에 배치:

```redis
counter:{user:123}:views
counter:{user:123}:likes
```

### TTL 설정

키 생성 시 바로 만료 설정, 업데이트 시 `EXPIRE` 함께 호출 또는 Lua로 원자 처리

### 모니터링

- `INFO stats`: `expired_keys`, `evicted_keys`
- 카운터 키 길이 주기적 점검

## 사용 시나리오별 추천

| 시나리오 | 추천 패턴 |
|----------|----------|
| 페이지뷰 | String + INCR |
| 좋아요 수 (중복 허용) | String + INCR |
| 좋아요 수 (중복 제거) | Set + SCARD |
| 리더보드 | Sorted Set + ZINCRBY |
| 일별 활성 사용자 (DAU) | HyperLogLog |
| 출석 체크 | Bitmap |
| API 레이트 리밋 | ZSET 타임스탬프 또는 키 분할 |

## 자가 체크

> - 내 카운팅 요구사항에서 정확도가 얼마나 중요한가?
> - 중복 제거가 필요하다면 Set vs HyperLogLog 중 어느 것이 적절한가?
> - 키를 일자별로 분리하고 있는가? TTL은 설정했는가?
> - 클러스터 환경이라면 해시 태그로 관련 키를 묶었는가?

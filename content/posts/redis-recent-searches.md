---
title: "최근 검색 기록은 Redis ZSET 하나로 처리했다"
url: "/backend/redis/2026/01/24/redis-recent-searches/"
date: 2026-01-24 19:00:00 +0900
categories: [backend, redis]
---

최근 검색 기록은 append list처럼 보이지만 요구사항이 조금 더 있다. 같은 검색어를 다시 검색하면 하나만 남기고 최신 위치로 올려야 한다. 최신순 조회가 필요하고, 오래된 항목도 잘라내야 한다.

이 요구사항에는 Redis ZSET이 잘 맞는다.

## 요구사항

| 항목 | 결정 |
|---|---|
| 단위 | 로그인 유저별 |
| 정렬 | 최신순 |
| 중복 | 같은 검색어는 하나만 유지 |
| 제한 | 최근 N개만 저장 또는 노출 |
| 보관 | 키 단위 TTL |
| 장애 | 저장 실패가 검색 자체를 막으면 안 됨 |

## 데이터 모델

```text
key    = recentsearch:{userId}
type   = ZSET
member = 정규화된 검색어
score  = 검색 시각
```

ZSET은 member가 유일하다. 같은 검색어를 다시 `ZADD`하면 score만 갱신되므로 중복 제거와 최신화가 동시에 된다.

```redis
ZADD recentsearch:42 1760000000000 "redis zset"
ZREVRANGE recentsearch:42 0 19
```

최신순 조회는 `ZREVRANGE`로 끝난다.

## 쓰기는 원자적으로 묶는다

저장할 때 필요한 작업은 세 가지다.

- 검색어 추가 또는 score 갱신
- TTL 갱신
- 최대 개수 초과분 제거

따로 실행하면 동시 요청에서 제한 개수가 깨질 수 있다. Lua로 묶는다.

```lua
-- KEYS[1]: recentsearch:{userId}
-- ARGV[1]: query
-- ARGV[2]: score
-- ARGV[3]: max_items
-- ARGV[4]: ttl_seconds
redis.call("ZADD", KEYS[1], ARGV[2], ARGV[1])
redis.call("EXPIRE", KEYS[1], ARGV[4])

local overflow = redis.call("ZCARD", KEYS[1]) - tonumber(ARGV[3])
if overflow > 0 then
  redis.call("ZREMRANGEBYRANK", KEYS[1], 0, overflow - 1)
end

return 1
```

score는 millisecond timestamp면 충분한 경우가 많다. 같은 ms에 여러 검색이 들어오는 것이 문제라면 `now_ms * 1000 + sequence`처럼 tie-breaker를 붙인다.

## API는 단순하게 둔다

```text
GET    /recent-searches?limit=20
DELETE /recent-searches/{query}
DELETE /recent-searches
```

각각 Redis 명령으로 바로 대응된다.

```redis
ZREVRANGE recentsearch:{userId} 0 19
ZREM recentsearch:{userId} {query}
DEL recentsearch:{userId}
```

## 검색어 정규화가 중요하다

정규화하지 않으면 `" 카페  라떼 "`, `"카페 라떼"`, `"카페라떼"`가 모두 다른 검색어가 된다.

최소한 아래 처리는 저장 전에 한다.

- 앞뒤 공백 제거
- 연속 공백 축약
- 길이 제한
- 필요하면 대소문자 정규화
- 한글/유니코드 입력은 NFC 정규화 검토

검색 기록에는 개인정보나 민감한 검색어가 들어갈 수 있다. TTL, 전체 삭제, 계정 삭제 시 키 삭제는 기능 요구사항이 아니라 개인정보 처리 요구사항에 가깝다.

## 장애 격리

최근 검색어 저장은 검색 기능의 부가 기능이다. Redis 장애 때문에 실제 검색 요청이 실패하면 안 된다.

```text
검색 실행 -> 결과 반환
          -> 최근 검색어 저장은 best effort
```

쓰기 실패는 로그나 비동기 재시도로 처리하고, 사용자 요청의 성공 여부와 분리한다.

## 남는 기준

최근 검색 기록은 "최신순 + 중복 제거 + 개수 제한"이 핵심이다. 이 셋을 한 자료구조에서 처리할 수 있어서 ZSET이 맞다. 구현의 품질은 Redis 명령을 아는 데서 갈리는 것이 아니라, 원자성, 정규화, TTL, 장애 격리를 같이 챙기는 데서 갈린다.

## 참고자료

- [Redis Sorted Sets](https://redis.io/docs/latest/develop/data-types/sorted-sets/)

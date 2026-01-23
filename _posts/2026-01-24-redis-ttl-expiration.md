---
layout: post
title: "Redis 키 만료, 제대로 이해하고 쓰기"
date: 2026-01-24 10:00:00 +0900
categories: [backend, redis]
---

Redis의 모든 키는 만료 시간(expiration)을 설정할 수 있습니다. 만료 시간이 지나면 키는 자동으로 삭제됩니다. 캐시, 세션, 임시 토큰 등 대부분의 Redis 사용 사례에서 TTL은 필수입니다.

## 먼저 생각해볼 것

> - 이 데이터는 영구 저장이 필요한가, 임시 데이터인가?
> - TTL 없이 저장하면 메모리가 무한정 늘어나지 않는가?
> - 만료 시점은 상대 시간(60초 후)이 좋은가, 절대 시간(자정)이 좋은가?

## TTL과 PTTL - 남은 시간 조회

### TTL (Time To Live)

키의 남은 만료 시간을 **초 단위**로 반환합니다.

```
> SET mykey "Hello"
OK
> EXPIRE mykey 10
(integer) 1
> TTL mykey
(integer) 10
```

**반환값:**
- 양수: 남은 만료 시간(초)
- `-1`: 키는 존재하지만 만료 시간이 설정되지 않음
- `-2`: 키가 존재하지 않음

### 자가 체크

> - TTL이 -1인 키가 많다면 메모리 누수의 징후일 수 있다. 의도한 것인가?
> - TTL이 -2를 반환했을 때 코드가 올바르게 처리하는가?

```python
def test_ttl_returns_minus_one_when_no_expiration(r: redis.Redis):
    """만료 시간이 설정되지 않은 키의 TTL은 -1을 반환한다."""
    r.set("key", "value")
    assert r.ttl("key") == -1


def test_ttl_returns_minus_two_when_key_not_exists(r: redis.Redis):
    """존재하지 않는 키의 TTL은 -2를 반환한다."""
    assert r.ttl("nonexistent_key") == -2
```

### PTTL (Precise TTL)

키의 남은 만료 시간을 **밀리초 단위**로 반환합니다.

```
> PTTL mykey
(integer) 9998
```

## EXPIRE와 PEXPIRE - 만료 시간 설정

### EXPIRE

키의 만료 시간을 **초 단위**로 설정합니다.

```
> SET mykey "Hello"
OK
> EXPIRE mykey 60
(integer) 1
> TTL mykey
(integer) 60
```

### PEXPIRE

키의 만료 시간을 **밀리초 단위**로 설정합니다.

```
> PEXPIRE mykey 5000
(integer) 1
> PTTL mykey
(integer) 4995
```

### 만료 후 자동 삭제

```python
def test_key_deleted_after_expiration(r: redis.Redis):
    """만료 시간이 지나면 키가 자동으로 삭제된다."""
    r.set("key", "value")
    r.pexpire("key", 100)  # 100ms 후 만료

    assert r.exists("key") == 1
    time.sleep(0.15)  # 150ms 대기
    assert r.exists("key") == 0
```

### 자가 체크

> - 세션 TTL로 30분을 쓴다면, 사용자가 29분에 활동했을 때 TTL을 갱신하는가?
> - 캐시 TTL이 너무 짧으면 DB 부하가 늘고, 너무 길면 stale 데이터가 보인다. 적절한가?

## EXPIREAT과 PEXPIREAT - 절대 시간으로 만료 설정

Unix 타임스탬프를 사용하여 특정 시점에 키가 만료되도록 설정합니다.

```
> SET mykey "Hello"
OK
> EXPIREAT mykey 1893456000  # 2030년 1월 1일
(integer) 1
```

```python
def test_expireat_sets_absolute_unix_timestamp(r: redis.Redis):
    """EXPIREAT는 Unix 타임스탬프로 만료 시간을 설정한다."""
    r.set("key", "value")
    expire_time = int(time.time()) + 60  # 60초 후
    result = r.expireat("key", expire_time)

    assert result == True
    ttl = r.ttl("key")
    assert 58 <= ttl <= 60
```

## PERSIST - 만료 제거

키의 만료 시간을 제거하여 영구적으로 유지되도록 합니다.

```
> SET mykey "Hello"
OK
> EXPIRE mykey 60
(integer) 1
> TTL mykey
(integer) 60
> PERSIST mykey
(integer) 1
> TTL mykey
(integer) -1
```

## SET 명령의 만료 옵션

SET 명령은 값 설정과 동시에 만료 시간을 설정할 수 있습니다.

### EX 옵션 - 초 단위 만료

```
> SET mykey "Hello" EX 60
OK
> TTL mykey
(integer) 60
```

### PX 옵션 - 밀리초 단위 만료

```
> SET mykey "Hello" PX 5000
OK
> PTTL mykey
(integer) 4998
```

### SETEX - 값과 만료를 원자적으로 설정

`SET key value EX seconds`와 동일하지만 원자적 연산입니다.

```
> SETEX mykey 60 "Hello"
OK
```

> SETEX는 원자적 연산이므로, SET과 EXPIRE를 별도로 실행하는 것보다 안전합니다. 두 명령 사이에 다른 클라이언트가 개입할 가능성이 없습니다.

### SET NX/EX 조합으로 락/멱등 처리

`NX`(키 없을 때만)와 `EX` 옵션을 함께 쓰면 락이나 멱등 토큰을 안전하게 설정할 수 있습니다.

```
SET order:123 processed NX EX 60
```

## GETEX - 조회와 만료 설정을 동시에 (Redis 6.2+)

값을 조회하면서 동시에 만료 시간을 설정하거나 제거할 수 있습니다.

```
> SET mykey "Hello"
OK
> GETEX mykey EX 60
"Hello"
> TTL mykey
(integer) 60
```

**옵션:**
- `EX seconds`: 초 단위 만료 설정
- `PX milliseconds`: 밀리초 단위 만료 설정
- `EXAT timestamp`: Unix 타임스탬프(초)로 만료 설정
- `PXAT milliseconds-timestamp`: Unix 타임스탬프(밀리초)로 만료 설정
- `PERSIST`: 만료 제거

## 주의사항

### 0초/음수 TTL은 즉시 삭제

`EXPIRE key 0` 또는 음수 TTL은 키를 즉시 삭제합니다.

### 만료는 키 단위로 동작

Hash나 List의 개별 필드/요소에는 만료를 설정할 수 없습니다. 전체 키에 대해서만 가능합니다.

```
> HSET user:1 name "Alice" age 30
(integer) 2
> EXPIRE user:1 60
(integer) 1
# 60초 후 user:1의 모든 필드가 삭제됨
```

### 키 덮어쓰기 시 만료 제거

키에 새 값을 설정하면 기존 만료 시간이 제거됩니다 (EX/PX 옵션을 사용하지 않는 경우).

```
> SET mykey "Hello" EX 60
OK
> TTL mykey
(integer) 60
> SET mykey "World"
OK
> TTL mykey
(integer) -1  # 만료가 제거됨
```

### 만료 삭제 방식

만료된 키는 두 가지 방법으로 삭제됩니다:

1. **Passive expiration**: 클라이언트가 만료된 키에 접근할 때 삭제
2. **Active expiration**: Redis가 주기적으로(초당 10회) 만료된 키를 샘플링하여 삭제

### 자가 체크

> - 만료된 키가 즉시 삭제되지 않을 수 있다는 점을 고려했는가?
> - `KEYS *` 명령으로 만료된 키가 보이더라도 GET하면 nil이 반환될 수 있다

### EXPIRE 조건 옵션 (Redis 7.0+)

```
EXPIRE key 600 NX   # 만료가 없을 때만 설정
EXPIRE key 600 XX   # 이미 만료가 있을 때만 갱신
EXPIRE key 600 GT   # 기존 TTL보다 더 길게 만들 때만
EXPIRE key 60 LT    # 기존 TTL보다 짧게 만들 때만
```

## 커맨드 요약

| 커맨드 | 설명 | 단위 |
|--------|------|------|
| `TTL key` | 남은 만료 시간 조회 | 초 |
| `PTTL key` | 남은 만료 시간 조회 | 밀리초 |
| `EXPIRE key seconds` | 만료 시간 설정 | 초 |
| `PEXPIRE key ms` | 만료 시간 설정 | 밀리초 |
| `EXPIREAT key timestamp` | 절대 시간으로 만료 설정 | Unix 초 |
| `PEXPIREAT key ms-timestamp` | 절대 시간으로 만료 설정 | Unix 밀리초 |
| `PERSIST key` | 만료 제거 | - |
| `SET key value EX seconds` | 값 설정과 만료 동시에 | 초 |
| `SET key value PX ms` | 값 설정과 만료 동시에 | 밀리초 |
| `SETEX key seconds value` | 값 설정과 만료 동시에 | 초 |
| `GETEX key [EX seconds]` | 조회와 만료 설정 동시에 | 초/밀리초 |

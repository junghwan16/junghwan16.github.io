---
layout: post
title: "Redis 키 관리 가이드"
date: 2026-01-24 18:00:00 +0900
categories: [backend, redis]
---

Redis에서 키를 효과적으로 관리하기 위한 규칙과 커맨드를 정리합니다.

## 키 네이밍 원칙

```
user:123:profile
session:{userId}
cache:post:{id}
otp:{phone}
```

- `:`로 계층을 나눔
- 영어/소문자/케밥 또는 스네이크를 일관되게
- 클러스터에서 **해시 태그**(`{}`)를 쓰면 멀티키 연산 가능
- TTL이 필요한 키는 이름에서 용도를 드러냄

## 키의 자동 생성과 삭제

### 규칙 1: 아이템 추가 시 자료 구조 자동 생성

```redis
> DEL mylist
> LPUSH mylist 1 2 3
(integer) 3  # LPUSH와 동시에 list 생성
```

단, 다른 자료 구조가 이미 존재하면 에러:

```redis
> SET hello world
> LPUSH hello 1 2 3
(error) WRONGTYPE Operation against a key holding the wrong kind of value
```

### 규칙 2: 모든 아이템 삭제 시 키도 자동 삭제

```redis
> LPUSH mylist 1 2 3
> LPOP mylist
> LPOP mylist
> LPOP mylist
> EXISTS mylist
(integer) 0
```

### 규칙 3: 없는 키에 읽기/삭제 시 빈 결과 반환

```redis
> DEL mylist
> LLEN mylist
(integer) 0
> LPOP mylist
(nil)
```

**주의**: `EXPIRE`가 걸린 키를 다른 자료구조로 교체하면 TTL 사라짐. `SET key value KEEPTTL` 사용.

## 키 조회 커맨드

### EXISTS - 존재 여부 확인

```redis
> SET key1 "value"
> EXISTS key1
(integer) 1
> EXISTS nonexistent
(integer) 0
> EXISTS key1 key2
(integer) 1  # 존재하는 키 개수
```

### KEYS - 패턴으로 검색 (주의!)

```redis
> KEYS h?llo
1) "hello"
2) "hallo"
```

> **운영 환경에서 KEYS 사용 금지**. 싱글 스레드인 Redis가 모든 키를 스캔하는 동안 다른 요청 처리 불가. 클러스터에서는 차단될 수 있음.

### SCAN - 안전한 키 순회

```redis
> SCAN 0 MATCH key* COUNT 10
1) "17"          # 다음 커서
2) 1) "key1"
   2) "key2"
```

- 커서 기반으로 일부씩 반환
- 완벽한 스냅샷 아님 (중간에 키 추가/삭제 가능)
- `COUNT`는 힌트일 뿐
- 커서가 0이 될 때까지 반복

```python
def scan_all_keys(r, pattern):
    cursor = 0
    all_keys = set()
    while True:
        cursor, keys = r.scan(cursor=cursor, match=pattern, count=100)
        all_keys.update(keys)
        if cursor == 0:
            break
    return all_keys
```

### TYPE - 자료 구조 타입 확인

```redis
> TYPE string_key
string
> TYPE list_key
list
> TYPE hash_key
hash
> TYPE zset_key
zset
```

## 키 삭제 커맨드

### DEL - 동기 삭제

```redis
> DEL key1 key2 nonexistent
(integer) 2  # 삭제된 키 개수
```

### UNLINK - 비동기 삭제

```redis
> UNLINK hugekey
```

- DEL과 동일하지만 메모리 해제는 백그라운드
- **큰 키 삭제 시 블로킹 방지**

### FLUSHDB / FLUSHALL

- `FLUSHDB`: 현재 DB의 모든 키 삭제
- `FLUSHALL`: 모든 DB의 모든 키 삭제
- **운영 환경 금지**

## 키 이름 변경

### RENAME

```redis
> SET old_key "value"
> RENAME old_key new_key
OK
> EXISTS old_key
(integer) 0
> GET new_key
"value"
```

### RENAMENX - 새 키가 없을 때만

```python
r.set("key1", "value1")
r.set("key2", "value2")
result = r.renamenx("key1", "key2")
# result == False, key2 덮어쓰지 않음
```

## 키 복사

### COPY (Redis 6.2+)

```redis
> COPY key1 key2
(integer) 1
> COPY key1 key2 REPLACE  # 덮어쓰기
(integer) 1
```

## 커맨드 요약

| 커맨드 | 설명 | 시간복잡도 |
|--------|------|-----------|
| `EXISTS key [key ...]` | 존재 여부 확인 | O(N) |
| `KEYS pattern` | 패턴 검색 (위험) | O(N) |
| `SCAN cursor [MATCH pattern]` | 안전한 순회 | O(1) per call |
| `TYPE key` | 타입 확인 | O(1) |
| `DEL key [key ...]` | 동기 삭제 | O(N) |
| `UNLINK key [key ...]` | 비동기 삭제 | O(1) |
| `RENAME key newkey` | 이름 변경 | O(1) |
| `RENAMENX key newkey` | 조건부 이름 변경 | O(1) |
| `COPY source dest` | 복사 | O(N) |

## 운영 모니터링

```redis
# DB별 키 수와 만료 키 수
INFO keyspace

# expired_keys, evicted_keys, keyspace_hits/misses
INFO stats

# 큰 키 점검
MEMORY USAGE <key>

# 키 폭증 표본 조사
SCAN 0 MATCH prefix:* COUNT 1000
```

## 주의사항

| 상황 | 대응 |
|------|------|
| KEYS 사용 | SCAN으로 대체 |
| 큰 키 삭제 | DEL 대신 UNLINK |
| TTL 유지하며 값 변경 | `SET key value KEEPTTL` |
| 클러스터 멀티키 연산 | 해시 태그 `{}` 사용 |

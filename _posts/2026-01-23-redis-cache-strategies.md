---
layout: post
title: "캐시가 필요할 때, Redis로 어떻게 구현할까"
date: 2026-01-23 19:00:00 +0900
categories: [backend, redis]
---

"DB 쿼리가 너무 느려요", "같은 데이터를 계속 조회해요" — 이런 상황에서 캐시 도입을 고민하게 됩니다. 이 글에서는 캐시의 기본 개념부터 Redis를 활용한 캐싱 전략, 그리고 실무에서 자주 발생하는 문제들을 다룹니다.

## 먼저 생각해볼 것

캐시를 도입하기 전에 스스로 물어보세요:

> - 현재 병목이 정말 DB 조회인가? (프로파일링 해봤는가?)
> - 같은 데이터를 얼마나 자주 조회하는가?
> - 데이터가 얼마나 자주 변경되는가?
> - 캐시가 틀린 데이터를 보여줘도 괜찮은가? (얼마나 오래?)

이 질문들에 명확히 답할 수 없다면, 캐시보다 쿼리 최적화나 인덱스 추가가 먼저일 수 있습니다.

## 캐시가 효과적인 경우

| 상황 | 설명 |
|------|------|
| 느린 응답 속도 | DB 조회에 수백 ms 이상 걸림 |
| 반복적인 연산 | 동일한 결과를 반복 계산 |
| 읽기 비율이 높음 | 쓰기보다 읽기가 10배 이상 |
| 약간의 지연 허용 | 실시간 정확성이 필수가 아님 |

## 왜 Redis인가?

- **Key-Value 구조**: 직관적인 저장과 조회
- **인메모리**: 디스크 DB보다 100배 이상 빠름
- **다양한 자료구조**: String, List, Hash, Set, Sorted Set
- **TTL 지원**: 자동 만료로 메모리 관리
- **고가용성**: Sentinel, Cluster로 장애 대응

## 읽기 전략: Cache-Aside

가장 널리 사용되는 패턴입니다.

```
요청 → 캐시 확인 → Hit? → 반환
                  ↓ Miss
            DB 조회 → 캐시 저장 → 반환
```

```python
def get_user(user_id: str) -> dict:
    cache_key = f"user:{user_id}"

    # 1. 캐시 조회
    cached = cache.get(cache_key)
    if cached:
        return json.loads(cached)

    # 2. 캐시 미스 - DB 조회
    user = db.get_user(user_id)

    # 3. 캐시에 저장 (TTL 60초)
    if user:
        cache.set(cache_key, json.dumps(user), ex=60)

    return user
```

### 자가 체크

> - 캐시 미스가 발생하면 어떤 일이 일어나는가?
> - TTL을 60초로 설정했는데, 이 시간 동안 원본 데이터가 바뀌면?
> - 캐시 서버가 죽으면 서비스는 어떻게 되는가?

## 쓰기 전략

### Write-Through (동시 쓰기)

DB와 캐시를 동시에 업데이트합니다.

```python
def update_user(user_id: str, data: dict) -> dict:
    # 1. DB 저장
    updated = db.update_user(user_id, data)

    # 2. 캐시에도 저장
    if updated:
        cache.set(f"user:{user_id}", json.dumps(updated), ex=60)

    return updated
```

**장점**: 캐시가 항상 최신
**단점**: 쓰기 지연 증가

### Cache Invalidation (캐시 무효화)

DB 업데이트 시 캐시를 삭제합니다.

```python
def update_user(user_id: str, data: dict) -> dict:
    updated = db.update_user(user_id, data)
    cache.delete(f"user:{user_id}")  # 삭제만!
    return updated
```

**장점**: 쓰기가 빠름
**단점**: 다음 읽기에서 캐시 미스 발생

### 자가 체크

> - 당신의 서비스는 읽기가 많은가, 쓰기가 많은가?
> - 사용자가 데이터를 수정하고 바로 조회하면 최신 데이터가 보여야 하는가?

## Write-Behind (쓰기 지연)

쓰기가 매우 빈번한 경우에 적합합니다.

```python
def update_likes(video_id: str) -> int:
    cache_key = f"video:{video_id}:likes"

    # 1. 캐시에 즉시 반영
    current = cache.incr(cache_key)

    # 2. 100번마다 DB에 배치 저장
    if current % 100 == 0:
        schedule_db_update(video_id, current)

    return current
```

**장점**: 쓰기가 매우 빠름, DB 부하 감소
**단점**: 캐시 장애 시 데이터 유실 위험

### 자가 체크

> - 이 데이터가 유실되면 비즈니스에 어떤 영향이 있는가?
> - "좋아요 수"와 "결제 금액" 중 어느 쪽에 이 패턴을 쓸 수 있는가?

## 메모리 관리

### TTL 설정

```bash
SET user:123 "data" EX 60  # 60초 후 만료
```

### maxmemory-policy

메모리 한도 도달 시 삭제 정책:

| 정책 | 설명 |
|------|------|
| `noeviction` | 추가 저장 차단 (기본값) |
| `allkeys-lru` | LRU 방식으로 삭제 **(캐시 용도 권장)** |
| `volatile-ttl` | TTL이 짧은 키부터 삭제 |

## Cache Stampede 문제

인기 있는 캐시가 만료되는 순간, 수많은 요청이 동시에 DB로 몰리는 현상입니다.

### 해결책 1: Mutex Lock

```python
def get_data_with_lock(key: str):
    data = cache.get(key)
    if data:
        return data

    lock_key = f"{key}:lock"
    if cache.set(lock_key, "1", nx=True, ex=10):  # 락 획득
        try:
            data = db.get(key)
            cache.set(key, data, ex=300)
            return data
        finally:
            cache.delete(lock_key)
    else:
        time.sleep(0.1)  # 락 획득 실패 - 대기
        return get_data_with_lock(key)
```

### 해결책 2: TTL에 Jitter 추가

```python
base_ttl = 300
jitter = random.randint(0, 60)
cache.set(key, data, ex=base_ttl + jitter)
```

만료 시점을 분산시켜 동시 만료를 방지합니다.

### 자가 체크

> - 당신의 캐시 중 "인기 있는" 키는 무엇인가?
> - 그 키가 만료되면 몇 개의 요청이 동시에 DB를 칠 수 있는가?

## Cache Penetration 문제

존재하지 않는 데이터를 반복 요청해서 DB에 불필요한 부하를 주는 상황입니다.

### 해결책: Null 값 캐싱

```python
def get_data(key: str):
    data = cache.get(key)
    if data is not None:
        return None if data == b"NULL" else json.loads(data)

    db_data = db.get(key)
    if db_data:
        cache.set(key, json.dumps(db_data), ex=300)
    else:
        cache.set(key, "NULL", ex=5)  # 없는 것도 짧게 캐싱

    return db_data
```

## 전략 선택 가이드

| 상황 | 추천 전략 |
|------|----------|
| 범용적인 읽기 캐싱 | Cache-Aside |
| 데이터 일관성이 중요 | Write-Through |
| 쓰기 성능이 중요 | Cache Invalidation |
| 쓰기가 매우 빈번 | Write-Behind |

## 마무리 체크리스트

도입 전:
- [ ] 캐시 없이 최적화할 수 있는 부분은 없는가?
- [ ] 캐시 장애 시 서비스가 어떻게 동작해야 하는가?

설계 시:
- [ ] TTL은 얼마로 설정할 것인가?
- [ ] 데이터 변경 시 캐시를 어떻게 처리할 것인가?
- [ ] 메모리 한도와 eviction 정책은?

운영 시:
- [ ] 캐시 히트율을 모니터링하고 있는가?
- [ ] Stampede 방어책이 있는가?

---

## 성능 벤치마크

실측 기준 (단일 Redis 인스턴스, 로컬 네트워크):

| 작업 | 평균 응답 시간 |
|------|---------------|
| Redis GET (캐시 히트) | **0.1~0.5ms** |
| MySQL SELECT (인덱스) | 1~10ms |
| MySQL SELECT (풀 스캔) | 100ms~수 초 |

캐시 히트 시 **10~100배** 빠르다. 네트워크 RTT 포함 시 실제 환경에서는 1~2ms 예상.

---

## 캐시 히트율 모니터링

```bash
redis-cli INFO stats | grep keyspace
```

```
keyspace_hits:1000000
keyspace_misses:50000
```

**히트율 계산:**

```python
hit_rate = hits / (hits + misses) * 100
# 1000000 / 1050000 * 100 = 95.2%
```

| 히트율 | 상태 | 조치 |
|--------|------|------|
| 95%+ | 양호 | 유지 |
| 80~95% | 보통 | TTL 조정 검토 |
| 80% 미만 | 주의 | 캐시 전략 재검토 |


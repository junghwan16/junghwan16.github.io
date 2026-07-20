---
title: "UPDATE 6건이 왜 1,600개의 InnoDB lock을 만들까"
url: "/backend/mysql/2026/07/19/innodb-lock-amplification/"
date: 2026-07-19 18:00:00 +0900
categories: [backend, mysql]
---

[앞 글](/backend/mysql/2026/07/18/innodb-primary-key-clustered-index/)에서는 InnoDB의 row가 clustered index에 저장되고 명시적인 PK가 row의 주소 역할을 한다는 점을 살펴봤다. 이제 “6건만 UPDATE했는데 왜 lock은 1,600개인가”를 설명할 차례다.

**이번 글에서 이해할 한 문장:** InnoDB의 UPDATE lock 수는 최종 수정 row 수보다 **대상을 찾기 위해 scan한 index record 수**에 더 가까울 수 있다.

## lock은 왜 필요한가

두 요청이 동시에 같은 쿠폰 상태를 바꾼다고 하자.

```text
요청 A: pending → issued
요청 B: pending → expired
```

둘이 아무 제약 없이 동시에 값을 바꾸면 마지막에 어떤 상태가 남을지 예측하기 어렵다. InnoDB는 한 트랜잭션이 row를 수정하는 동안 다른 트랜잭션이 충돌하는 수정을 하지 못하도록 lock을 사용한다.

```text
트랜잭션 A가 row에 X lock 획득
  ↓
트랜잭션 B가 같은 row의 X lock 요청
  ↓
B는 A가 COMMIT 또는 ROLLBACK할 때까지 대기
```

- **트랜잭션**은 함께 성공하거나 함께 취소되어야 하는 작업 단위다.
- **X lock**은 exclusive lock의 줄임말로, 해당 row를 수정하거나 삭제할 권한을 한 트랜잭션이 독점한다.
- **COMMIT**은 변경을 확정하고, **ROLLBACK**은 변경을 취소한다.

이 글에서는 여러 lock 종류를 모두 외우지 않는다. UPDATE 중 index record에 잡히는 X lock에만 집중한다.

## row lock이라고 row만 잠그는 것은 아니다

InnoDB의 record lock은 추상적인 “row 번호”가 아니라 **index record**를 잠근다. PK를 사용했다면 PK index record가, secondary index를 사용했다면 그 secondary index record가 탐색 과정에 등장한다.

## 수정한 row와 찾으려고 본 row는 다르다

다음 UPDATE가 최종적으로 쿠폰 발급 요청 6건만 만료시켰다고 하자.

```sql
UPDATE coupon_issue_history
SET status = 'expired', updated_at = NOW()
WHERE campaign_id = 17
  AND status = 'pending'
  AND requested_at < NOW() - INTERVAL 5 MINUTE
ORDER BY requested_at
LIMIT 20;
```

흔히 “6건을 바꿨으니 X lock도 6개겠지”라고 생각한다. 그러나 InnoDB는 UPDATE를 처리하면서 scan한 index record에 record lock을 설정한다. WHERE 조건에서 탈락한 row가 있더라도 어떤 index 범위를 scan했는지가 중요하다.

```text
최종 수정 row: 6
대상을 찾기 위해 scan한 index record: 800
관측 가능한 record lock: 6보다 훨씬 많을 수 있음
```

정확한 lock 종류와 범위는 인덱스, 검색 조건, 격리 수준에 따라 달라진다. 여기서 핵심은 “수정 건수만 보고 lock 수를 예측할 수 없다”는 점이다.

## unique point lookup은 탐색 범위가 작다

PK로 한 row를 찾는 UPDATE를 보자.

```sql
UPDATE coupon_issue_history
SET status = 'expired'
WHERE id = 93012;
```

`id`가 PK라면 InnoDB는 unique search로 정확한 index record 하나를 찾을 수 있다.

```text
PK 93012 검색
  ↓
한 record 발견
  ↓
그 record에 X lock
```

unique index와 unique search condition을 사용하는 경우에는 찾은 index record만 잠그며 앞의 gap은 잠그지 않는다.

## non-unique range scan은 탐색 범위가 넓다

일반 인덱스는 같은 값의 record가 여러 개일 수 있다.

```sql
KEY idx_requested_at (requested_at)
```

특정 시각에 쿠폰 발급 요청이 몰리면 같은 초 주변에 수백 개의 record가 쌓인다. non-unique index로 범위를 훑는 UPDATE는 그 index range의 여러 record를 만난다.

```text
idx_requested_at

10:00:00 → 240 records
10:00:01 → 310 records
10:00:02 → 280 records
```

최종 조건에 맞는 row가 6개여도 찾는 과정에서는 훨씬 많은 record를 scan할 수 있다.

## secondary index와 clustered index에서 lock이 함께 보이는 이유

secondary index를 이용한 search에서 exclusive lock이 필요하면 InnoDB는 대응하는 clustered index record도 찾아 lock을 설정한다.

```text
idx_requested_at record에 X lock
  ↓
record에 저장된 PK로 clustered index 이동
  ↓
clustered index record에도 X lock
```

PK가 없는 테이블이라면 clustered index 이름은 `GEN_CLUST_INDEX`로 보일 수 있다.

```text
index_name       lock_mode       lock_count
idx_requested_at X,REC_NOT_GAP          806
GEN_CLUST_INDEX  X,REC_NOT_GAP          806
```

이 예에서는 UPDATE row가 6개인데 두 인덱스에서 합계 1,612개의 record lock이 관측된다. 숫자가 거의 쌍으로 보이는 이유는 secondary record와 그에 대응하는 clustered record가 함께 잠겼기 때문이다.

## RBR applier에서는 scan이 더 낯설게 보인다

source에서는 원래 UPDATE가 복합 인덱스를 사용해 6건을 빠르게 찾았을 수 있다.

```text
source SQL
  idx_campaign_status_requested 사용
  6건 수정
```

하지만 Row-based replication의 applier는 원래 SQL과 실행 계획을 받지 않는다. before image와 Replica의 인덱스로 row를 다시 찾는다.

PK나 `NOT NULL` UNIQUE 키가 없고 일반 인덱스만 있다면, applier는 row event의 before image를 hash table에 담고 선택한 일반 인덱스로 target table의 record를 순회한다.

```text
row event: 변경할 6개 row의 before image
  ↓
hash table 생성
  ↓
idx_requested_at record 순회
  ↓
각 record가 6개 중 하나인지 비교
  ↓
일치하면 UPDATE
```

따라서 source에서 6건을 찾은 비용과 Replica에서 그 6건을 다시 찾는 비용은 다를 수 있다.

## 병렬 worker가 만나면 lock amplification이 대기로 바뀐다

한 worker가 넓은 index 구간을 scan하며 많은 record lock을 잡는 것만으로도 느리다. 여러 applier worker가 인접한 시각 구간을 동시에 scan하면 더 큰 문제가 생긴다.

```text
worker A: 09:59:58부터 scan하며 lock 보유
worker B: 09:59:59부터 scan하다 A의 lock 대기
worker C: 10:00:00부터 scan하다 B의 lock 대기
```

각 트랜잭션은 서로 다른 최종 row를 수정하더라도 **찾는 과정의 scan 범위**가 겹칠 수 있다. 그러면 worker가 서로 기다리는 convoy가 만들어진다.

lock을 기다리는 thread는 CPU와 I/O를 거의 사용하지 않는다. 그래서 다음 조합이 가능하다.

```text
CPU: 낮음
IOPS: 낮음
applier: lock wait
Replica lag: 계속 증가
```

## 실제로 lock amplification을 확인하는 방법

먼저 진행 중인 트랜잭션에서 수정 row와 lock 수를 비교한다.

```sql
SELECT trx_id,
       trx_state,
       trx_started,
       trx_rows_locked,
       trx_rows_modified,
       trx_mysql_thread_id
FROM information_schema.innodb_trx
ORDER BY trx_started;
```

예를 들어 다음 결과는 point lookup으로 설명하기 어렵다.

```text
trx_state  trx_rows_locked  trx_rows_modified
RUNNING               1812                  8
LOCK WAIT             1460                  6
```

어느 인덱스에 lock이 몰렸는지도 집계한다.

```sql
SELECT engine_transaction_id,
       index_name,
       lock_type,
       lock_mode,
       lock_status,
       COUNT(*) AS lock_count
FROM performance_schema.data_locks
WHERE object_schema = 'app'
  AND object_name = 'coupon_issue_history'
GROUP BY 1, 2, 3, 4, 5
ORDER BY lock_count DESC;
```

마지막으로 대기 관계를 본다.

```sql
SELECT requesting.engine_transaction_id AS waiting_trx,
       blocking.engine_transaction_id AS blocking_trx,
       requesting.index_name,
       requesting.lock_data
FROM performance_schema.data_lock_waits AS waits
JOIN performance_schema.data_locks AS requesting
  ON requesting.engine_lock_id = waits.requesting_engine_lock_id
 AND requesting.engine = waits.engine
JOIN performance_schema.data_locks AS blocking
  ON blocking.engine_lock_id = waits.blocking_engine_lock_id
 AND blocking.engine = waits.engine;
```

`waiting_trx`와 `blocking_trx`를 `performance_schema.threads`까지 연결하면 외부 세션이 막는지, applier worker끼리 막는지 구분할 수 있다.

## lock 수가 많으면 무조건 PK가 원인인가

아니다. lock amplification은 현상이고 원인은 여러 가지다.

- WHERE 조건에 맞는 인덱스가 없어 원래 UPDATE가 넓게 scan할 수 있다.
- non-unique range update가 넓은 범위를 잠글 수 있다.
- 격리 수준에 따라 gap lock과 next-key lock 범위가 달라질 수 있다.
- RBR applier가 식별 키 없이 일반 인덱스 또는 table scan으로 row를 찾을 수 있다.

따라서 `trx_rows_locked` 하나만 보고 결론 내리지 않는다. 다음 증거를 연결해야 한다.

1. 해당 트랜잭션이 applier worker인가
2. 실패한 이벤트가 UPDATE 또는 DELETE인가
3. 테이블에 PK나 `NOT NULL` UNIQUE 키가 없는가
4. `data_locks`가 어느 인덱스에 집중되는가
5. `data_lock_waits`의 blocker도 applier worker인가

## 여기까지의 기준

1. UPDATE는 최종 수정 row가 아니라 scan한 index record를 기준으로 더 많은 lock을 잡을 수 있다.
2. secondary index로 X lock을 잡으면 대응하는 clustered index record도 잠길 수 있다.
3. RBR applier에 식별 키가 없으면 일반 인덱스 scan이 lock amplification으로 이어질 수 있다.
4. 여러 worker의 scan 범위가 겹치면 CPU는 낮아도 lock wait와 Replica lag가 커질 수 있다.

이제 필요한 조각을 모두 배웠다. 마지막 글에서는 [쿠폰 발급 시스템의 Replica lag를 로그와 lock 정보로 추적하는 전체 과정](/backend/mysql/2026/07/20/mysql-replica-update-primary-key/)을 다시 따라간다.

## 참고자료

- [MySQL Reference Manual — Locks Set by Different SQL Statements in InnoDB](https://dev.mysql.com/doc/refman/8.4/en/innodb-locks-set.html)
- [MySQL Reference Manual — InnoDB Locking](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking.html)
- [MySQL Reference Manual — Replication and Row Searches](https://dev.mysql.com/doc/refman/8.4/en/replication-features-row-searches.html)

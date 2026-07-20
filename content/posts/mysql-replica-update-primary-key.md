---
title: "CPU는 한가로운데 Replica lag가 늘었다: UPDATE 테이블에 PK가 필요한 이유"
url: "/backend/mysql/2026/07/20/mysql-replica-update-primary-key/"
date: 2026-07-20 18:00:00 +0900
categories: [backend, mysql]
---

새벽 1시 42분, 대규모 쿠폰 발급 시스템의 당직 엔지니어에게 경보가 왔다.

> MySQL Replica lag: 12초 → 9분, 계속 증가 중

그런데 이상했다. Replica의 CPU는 20% 아래였고 IOPS에도 여유가 있었다. source의 응답 시간도 평소와 비슷했다. 서버가 바쁘지 않은데 복제만 밀리고 있었다.

결론부터 말하면 원인은 UPDATE가 발생하는 대형 테이블에 PK나 `NOT NULL` UNIQUE 키가 없었던 것이었다. row-based replication의 applier가 변경할 row를 바로 찾지 못해 일반 인덱스를 훑었고, 적은 row를 수정하면서도 많은 row lock을 잡았다. 병렬 worker들은 같은 인덱스 구간에서 서로 기다리기 시작했고, 재시도가 누적되며 Replica lag가 커졌다.

이 글의 쿠폰 발급 시스템, 테이블, 시각, 식별자와 관측 수치는 실제 조사 경험을 바탕으로 재구성한 가상 예시다. 다만 MySQL의 동작과 진단 방법은 MySQL 8.4 기준이다.

## 사고 전의 구조

사용자가 쿠폰 발급을 요청하면 이력은 `coupon_issue_history`에 `pending` 상태로 쌓인다. 발급이 완료되면 `issued`로 바뀌고, 재고 소진이나 처리 시간 초과로 발급하지 못한 요청은 잠시 뒤 `expired`로 바뀐다.

테이블은 월간 파티션으로 관리했고 전체 row 수는 약 1억 4천만 건이었다.

```sql
CREATE TABLE coupon_issue_history (
    campaign_id BIGINT UNSIGNED NOT NULL,
    user_id BIGINT UNSIGNED NOT NULL,
    issue_token VARCHAR(64) NOT NULL,
    status VARCHAR(20) NOT NULL,
    issue_metadata JSON NOT NULL,
    requested_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    KEY idx_requested_at (requested_at),
    KEY idx_user_requested (user_id, requested_at),
    KEY idx_campaign_status_requested (campaign_id, status, requested_at)
) ENGINE=InnoDB
PARTITION BY RANGE COLUMNS(requested_at) (
    PARTITION p202607 VALUES LESS THAN ('2026-08-01'),
    PARTITION pmax VALUES LESS THAN (MAXVALUE)
);
```

조회용 일반 인덱스는 여러 개였지만 PK와 UNIQUE 키는 없었다. 애플리케이션에서는 보통 다음과 같이 몇 건의 상태를 변경했다.

```sql
UPDATE coupon_issue_history
SET status = 'expired', updated_at = NOW()
WHERE campaign_id = 17
  AND status = 'pending'
  AND requested_at < NOW() - INTERVAL 5 MINUTE
ORDER BY requested_at
LIMIT 20;
```

source에서 이 쿼리는 빨랐다. `idx_campaign_status_requested`로 대상 범위를 좁혀 처리 시간이 지난 발급 요청 몇 건만 수정했다. 그래서 처음에는 이 UPDATE가 Replica 장애의 원인일 것이라고 생각하지 못했다.

## 01:45 — CPU와 IOPS는 범인이 아니었다

당직 엔지니어는 먼저 익숙한 지표를 확인했다.

| 지표 | 관측 |
|---|---|
| CPU | 18%, 평소와 비슷함 |
| Read/Write IOPS | 한도에 여유 있음 |
| Free memory | 급격한 변화 없음 |
| Source query latency | 평소 범위 |
| Replica lag | 계속 증가 |

리소스가 부족해서 applier가 source의 쓰기량을 못 따라가는 상황과는 모습이 달랐다. 다음으로 receiver와 applier 중 어디가 멈췄는지 확인했다.

```sql
SHOW REPLICA STATUS\G
```

주요 필드는 다음과 같다.

| 항목 | 확인할 내용 |
|---|---|
| `Replica_IO_Running` | source의 binlog를 계속 받고 있는가 |
| `Replica_SQL_Running` | applier가 동작 중인가 |
| `Seconds_Behind_Source` | 지연이 증가하는가 |
| `Last_SQL_Errno` | 1205, 1213 같은 락 오류가 있는가 |
| `Last_SQL_Error` | 어느 GTID에서 왜 실패했는가 |

이 시스템의 Replica는 IO thread가 정상적으로 binlog를 받고 있었다. 반면 SQL applier 쪽에는 lock wait timeout이 남아 있었다.

이 조합이 중요하다.

```text
receiver: 새 binlog를 계속 받음
applier:  기존 row event를 적용하지 못함
결과:     서버는 조용한데 relay log와 Replica lag만 증가
```

## 01:50 — 에러 로그가 applier를 가리켰다

Replica 에러 로그에는 같은 트랜잭션을 여러 번 재시도하다 포기한 흔적이 있었다. 식별자는 가렸다.

```text
[Repl] worker thread retried transaction 10 time(s) in vain, giving up
[Repl] Worker 2 failed executing transaction '<GTID>'
       Lock wait timeout exceeded; try restarting transaction
[Repl] Error running query, replica SQL thread aborted
```

이 로그로 세 가지를 알 수 있었다.

1. receiver가 아니라 SQL applier worker에서 실패했다.
2. 실패 원인은 CPU나 I/O 부족이 아니라 InnoDB lock wait timeout이었다.
3. 일시적인 충돌로 끝나지 않고 같은 트랜잭션의 재시도가 모두 소진됐다.

Replica를 다시 시작하자 잠깐 움직였지만 얼마 뒤 같은 GTID 근처에서 다시 멈췄다. 재시작은 현재 락을 정리했을 뿐, 같은 row search와 병렬 적용 조건을 그대로 재현하고 있었다.

## 02:00 — binlog에는 원래 UPDATE 문이 없었다

에러 로그의 GTID와 binlog position을 이용해 문제 구간을 디코딩했다.

```bash
mysqlbinlog \
  --base64-output=DECODE-ROWS \
  --verbose \
  --start-position=<START_POS> \
  --stop-position=<END_POS> \
  mysql-bin.000123
```

문제 트랜잭션은 수십 MB짜리 배치가 아니었다. `coupon_issue_history`에서 처리되지 않은 쿠폰 발급 요청 6건을 만료시키는 작은 `Update_rows` 이벤트였다.

```text
### UPDATE `app`.`coupon_issue_history`
### WHERE
###   @1=17
###   @2=42001
###   @3='coupon-001'
###   @4='pending'
###   ...
### SET
###   @1=17
###   @2=42001
###   @3='coupon-001'
###   @4='expired'
###   ...
```

여기서 `WHERE`는 source가 실행한 원래 WHERE 절이 아니다. `mysqlbinlog -vv`가 row event의 **변경 전 이미지(before image)**를 사람이 읽기 좋게 보여준 것이다.

이 시스템은 `binlog_format=ROW`를 사용했다. 이 방식에서 Replica는 source의 UPDATE 문이나 실행 계획을 전달받지 않는다.

```text
source:  UPDATE 실행 → 변경된 row의 before/after image 기록
replica: row event 수신 → before image와 일치하는 row 탐색 → after image 적용
```

source가 `idx_campaign_status_requested`로 빠르게 UPDATE했다는 사실은 Replica의 row 탐색 경로를 보장하지 않았다. Replica는 자기 테이블의 인덱스와 row image만 보고 변경 대상을 다시 찾아야 했다.

복제 형식과 row image 설정은 다음처럼 확인할 수 있다.

```sql
SHOW GLOBAL VARIABLES
WHERE variable_name IN ('binlog_format', 'binlog_row_image');
```

## 02:08 — PK가 없으면 row를 어떻게 찾을까

MySQL은 row-based replication의 UPDATE 또는 DELETE를 적용할 때 다음 순서로 인덱스를 고른다.

1. Primary Key
2. 모든 컬럼이 `NOT NULL`인 UNIQUE 인덱스
3. 그 밖의 사용 가능한 인덱스
4. 사용 가능한 인덱스가 없으면 table scan

PK나 적절한 UNIQUE 키가 있으면 row event마다 point lookup을 할 수 있다. 일반 인덱스만 있으면 이벤트의 before image로 hash table을 만들고, 선택한 인덱스의 레코드를 순회하며 일치 여부를 비교한다. 사용할 인덱스조차 없으면 테이블을 훑는다.

| Replica 테이블의 키 | row 탐색 |
|---|---|
| PK | row마다 PK point lookup |
| 모든 컬럼이 `NOT NULL`인 UNIQUE 키 | row마다 unique point lookup |
| 일반 인덱스 또는 nullable UNIQUE 키 | 인덱스를 순회하며 before image와 대조 |
| 사용 가능한 인덱스 없음 | table scan하며 before image와 대조 |

nullable UNIQUE 키는 MySQL에서 여러 `NULL`을 허용한다. 따라서 “이 값은 정확히 한 row를 가리킨다”는 식별 키로 사용되지 않는다. 복합 UNIQUE 키도 모든 구성 컬럼이 `NOT NULL`이어야 한다.

또한 MySQL은 row event의 before image에 인덱스 컬럼이 모두 들어 있어야 그 인덱스를 후보로 삼는다. `binlog_row_image=MINIMAL`이라면 스키마에 인덱스가 있다는 사실만으로 항상 사용할 수 있는 것은 아니다.

## 02:15 — 테이블에는 주소가 없었다

당직 엔지니어는 문제 테이블의 실제 정의를 확인했다.

```sql
SHOW CREATE TABLE app.coupon_issue_history\G
```

PK도 없고 모든 컬럼이 `NOT NULL`인 UNIQUE 키도 없었다. 일반 인덱스 중 왼쪽에 있는 `idx_requested_at`이 Replica row search에 선택될 수 있는 구조였다.

스키마 전체에서 PK 없는 테이블도 찾았다.

```sql
SELECT t.table_schema, t.table_name, t.table_rows
FROM information_schema.tables AS t
LEFT JOIN information_schema.table_constraints AS c
  ON c.table_schema = t.table_schema
 AND c.table_name = t.table_name
 AND c.constraint_type = 'PRIMARY KEY'
WHERE t.table_type = 'BASE TABLE'
  AND t.table_schema NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
  AND c.constraint_name IS NULL
ORDER BY t.table_rows DESC;
```

몇 개의 로그 테이블이 더 나왔지만 모두 같은 위험도를 가진 것은 아니었다. 한 테이블은 INSERT만 발생했고, `coupon_issue_history`에는 지속적인 UPDATE가 들어왔다.

INSERT는 새 row를 추가하므로 Replica가 기존 row를 찾을 필요가 없다. UPDATE와 DELETE는 기존 row를 찾아야 한다. 따라서 **PK 없는 테이블 전체가 아니라, UPDATE 또는 DELETE가 발생하는 큰 테이블이 우선 조사 대상**이다.

## 02:20 — worker들이 같은 자리에서 재시도하고 있었다

병렬 applier의 worker 상태를 확인했다.

```sql
SELECT worker_id,
       thread_id,
       service_state,
       applying_transaction,
       applying_transaction_start_apply_timestamp,
       applying_transaction_retries_count,
       applying_transaction_last_transient_error_number,
       applying_transaction_last_transient_error_message
FROM performance_schema.replication_applier_status_by_worker;
```

4개 worker 중 여러 개가 서로 다른 GTID를 적용 중이었고, 재시도 횟수가 함께 증가하고 있었다. 마지막 transient error는 lock wait timeout 또는 deadlock이었다.

전체 재시도 누적값도 계속 늘었다.

```sql
SELECT channel_name,
       service_state,
       count_transactions_retries
FROM performance_schema.replication_applier_status;
```

`COUNT_TRANSACTIONS_RETRIES`는 누적값이므로 한 번 본 숫자만으로 원인을 확정할 수 없다. 짧은 간격으로 다시 조회해 증가 여부를 보고, worker별 현재 GTID와 error를 같이 봐야 한다.

worker들은 외부 세션 하나를 기다리는 것이 아니라 서로 다른 applier 트랜잭션을 재시도하는 모습이었다. 이제 실제 InnoDB lock을 확인할 차례였다.

## 02:24 — 6개 row를 바꾸는데 1,600개가 잠겨 있었다

진행 중인 InnoDB 트랜잭션을 조회했다.

```sql
SELECT trx_id,
       trx_state,
       trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_sec,
       trx_rows_locked,
       trx_rows_modified,
       trx_mysql_thread_id,
       trx_query
FROM information_schema.innodb_trx
ORDER BY trx_started;
```

익명화한 결과는 다음과 같았다.

```text
trx_state  age_sec  trx_rows_locked  trx_rows_modified
RUNNING        180             1812                  8
LOCK WAIT       31             1460                  6
LOCK WAIT       29             1324                  7
```

수치보다 비율이 중요하다. 6~8개 row를 수정하는 트랜잭션이 1,000개가 넘는 row lock을 보유하고 있었다. point lookup이라면 설명하기 어려운 락 증폭이었다.

`trx_query`는 `NULL`로 나왔다. 처음에는 쿼리를 끝내고 커밋하지 않은 idle client를 의심할 수 있다. 하지만 replication applier처럼 SQL 문자열 없이 내부 row event를 적용하는 thread도 `NULL`로 보일 수 있다.

`trx_mysql_thread_id`를 Performance Schema thread와 연결하자 모두 applier worker로 확인됐다.

```sql
SELECT t.processlist_id,
       t.name,
       t.processlist_user,
       t.processlist_state,
       t.processlist_info
FROM performance_schema.threads AS t
WHERE t.processlist_id IN (<TRX_MYSQL_THREAD_IDS>);
```

외부의 장기 트랜잭션이 아니라 replication worker들이 직접 락을 보유하고 있었다.

## 02:28 — 락이 몰린 인덱스가 보였다

`data_locks`에서 문제 테이블의 락을 인덱스별로 집계했다.

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

락은 `idx_requested_at`과 `GEN_CLUST_INDEX`에 집중되어 있었다.

```text
index_name       lock_type  lock_mode      lock_count
idx_requested_at RECORD     X,REC_NOT_GAP         906
GEN_CLUST_INDEX  RECORD     X,REC_NOT_GAP         906
```

`GEN_CLUST_INDEX`는 InnoDB 테이블에 PK나 적절한 UNIQUE `NOT NULL` 인덱스가 없을 때 내부 row ID로 만드는 숨은 clustered index다. replication row search는 이 숨은 인덱스를 빠른 식별 키로 선택하지 못한다. 일반 secondary index를 훑으면서 secondary record와 clustered record를 함께 잠그기 때문에 두 인덱스의 락이 같이 관측될 수 있다.

누가 누구를 기다리는지도 확인했다.

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

대기 관계의 양쪽이 모두 applier worker였고, 같은 `idx_requested_at` 구간에서 대기 체인이 만들어졌다.

```text
worker C waits for worker B
worker B waits for worker A
```

이것이 결정적인 증거였다. 외부 사용자의 장기 트랜잭션이 Replica를 막은 것이 아니라, 일반 인덱스를 넓게 훑는 병렬 worker들이 서로의 적용을 지연시키고 있었다.

## 원인은 하나의 느린 쿼리가 아니라 구조였다

이 장애는 다음 순서로 만들어졌다.

```text
PK와 NOT NULL UNIQUE 키 없음
  ↓
RBR applier가 UPDATE 대상 row를 point lookup하지 못함
  ↓
idx_requested_at을 순회하며 before image와 대조
  ↓
수정 row 수보다 훨씬 많은 record lock 보유
  ↓
병렬 worker의 탐색 구간이 겹치며 서로 대기
  ↓
lock timeout / deadlock → 트랜잭션 재시도
  ↓
applier 처리량 감소 또는 SQL thread 중단
  ↓
receiver는 계속 수신 → CPU·IOPS는 조용한데 lag 증가
```

그래서 source의 UPDATE 실행 시간이 짧았고, Replica의 전체 CPU와 IOPS가 낮았던 것도 모순이 아니었다.

- applier worker 몇 개만 바쁘면 다중 코어 전체 CPU 그래프에서는 작게 보인다.
- hot partition이 buffer pool에 있으면 인덱스 순회가 메모리에서 일어나 IOPS가 크게 늘지 않을 수 있다.
- lock wait 상태의 worker는 CPU와 I/O를 거의 쓰지 않는다.
- receiver가 계속 binlog를 받으면 적용되지 않은 양과 lag만 증가한다.

## 02:35 — 복구와 해결은 달랐다

### 즉시 완화

worker끼리 충돌하는 것이 직접 확인된 뒤 `replica_parallel_workers`를 일시적으로 1로 낮췄다. 병렬 처리량을 포기하는 대신 worker 간 대기 체인을 없애는 선택이었다.

이 방법이 모든 Replica lag의 해법은 아니다. 단일 worker의 row search 속도도 source의 유입량을 따라가지 못하면 lag는 계속 증가한다. 적용 전후 `Seconds_Behind_Source`가 감소하는지 확인해야 한다.

재부팅, worker kill, `replica_transaction_retries` 증가는 근본 해결이 아니었다.

- 재부팅이나 kill은 현재 락을 풀지만 같은 row search가 다시 실행된다.
- 재시도 횟수를 늘리면 우연한 충돌에는 도움이 되지만 구조적인 충돌에서는 실패까지 걸리는 시간만 늘어날 수 있다.

### 근본 해결

근본 해결은 수정되는 테이블에 PK 또는 모든 컬럼이 `NOT NULL`인 UNIQUE 키를 두는 것이다.

먼저 자연키를 검토했다.

```sql
ALTER TABLE coupon_issue_history
ADD CONSTRAINT uk_coupon_issue_token
UNIQUE (issue_token, requested_at);
```

파티션 테이블의 모든 UNIQUE 키는 파티션 표현식에 사용되는 컬럼을 포함해야 하므로 `requested_at`도 넣었다. 하지만 클라이언트가 응답을 받지 못해 발급 요청을 재시도하면 원래의 `issue_token`과 `requested_at`을 유지한 이력이 여러 건 남을 수 있었다. 자연키를 UNIQUE로 만들면 기존 DDL이 실패하거나 허용해 온 재시도 INSERT가 duplicate key error로 바뀐다.

그래서 짧은 surrogate key를 선택했다.

```sql
ALTER TABLE coupon_issue_history
  ADD COLUMN id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  ADD PRIMARY KEY (id, requested_at);
```

`requested_at`은 파티션 키 제약 때문에 PK에 포함했다. 짧은 surrogate key를 택한 이유도 있다. InnoDB의 secondary index에는 clustered primary key 값이 함께 저장된다. 긴 자연키를 PK로 쓰면 기존 secondary index 전체가 커질 수 있다.

수억 row 테이블에 PK를 추가하는 DDL은 그 자체로 위험하다. 테이블 재구성 시간, 추가 디스크 공간, metadata lock과 쓰기 영향을 확인해야 한다. 운영 테이블에 즉시 ALTER하지 않고, PK가 있는 새 테이블을 만든 뒤 쓰기와 읽기를 순차적으로 전환했다.

PK 적용 후에는 같은 `Update_rows`가 point lookup으로 처리됐고, 비정상적인 lock 증폭과 transaction retry 증가가 멈췄다. 그 뒤 병렬 worker 수를 원래 값으로 돌렸다.

## 다음 장애에서 바로 실행할 순서

이 사건 이후 운영팀은 Replica lag 대응 순서를 다음처럼 정리했다.

### 1. receiver와 applier를 구분한다

```sql
SHOW REPLICA STATUS\G
```

- IO thread만 정상인가
- SQL thread가 멈췄는가
- 마지막 SQL error가 lock 관련인가

### 2. worker의 현재 GTID와 재시도를 본다

```sql
SELECT worker_id,
       applying_transaction,
       applying_transaction_retries_count,
       applying_transaction_last_transient_error_number,
       applying_transaction_last_transient_error_message
FROM performance_schema.replication_applier_status_by_worker;

SELECT channel_name, count_transactions_retries
FROM performance_schema.replication_applier_status;
```

### 3. 수정 row와 잠긴 row의 차이를 본다

```sql
SELECT trx_id,
       trx_state,
       trx_started,
       trx_rows_locked,
       trx_rows_modified,
       trx_mysql_thread_id,
       trx_query
FROM information_schema.innodb_trx
ORDER BY trx_started;
```

### 4. 락 인덱스와 대기 관계를 남긴다

```sql
SELECT engine_transaction_id,
       index_name,
       lock_type,
       lock_mode,
       lock_status,
       COUNT(*) AS lock_count
FROM performance_schema.data_locks
GROUP BY 1, 2, 3, 4, 5
ORDER BY lock_count DESC;

SELECT *
FROM performance_schema.data_lock_waits;
```

### 5. 실패한 binlog event와 테이블 키를 확인한다

```sql
SHOW CREATE TABLE app.coupon_issue_history\G
```

```bash
mysqlbinlog --base64-output=DECODE-ROWS --verbose \
  --start-position=<START_POS> \
  --stop-position=<END_POS> \
  mysql-bin.000123
```

## 사고 순간의 증거를 남겨야 한다

`information_schema.innodb_trx`, `performance_schema.data_locks`, `data_lock_waits`는 현재 상태다. 사고가 끝나면 기다리던 트랜잭션과 락도 사라진다.

에러 로그만으로는 과거의 lock timeout을 알 수 있지만, 당시 누가 어떤 인덱스에서 누구를 막았는지까지 직접 증명하기 어렵다. 그래서 lag 경보가 발생하면 다음 결과를 자동으로 저장하도록 했다.

- `SHOW REPLICA STATUS`
- `replication_applier_status_by_worker`
- `replication_applier_status`
- `information_schema.innodb_trx`
- `performance_schema.data_locks`
- `performance_schema.data_lock_waits`

과거 사고에 이 스냅샷이 없다면 “동일한 기전이었다”는 결론은 강한 정황 추론일 수는 있어도 직접 관측은 아니다. 관측된 사실과 추론을 구분해서 기록해야 한다.

## 재발 방지 점검표

- `binlog_format=ROW`인가
- UPDATE/DELETE가 집중되는 큰 테이블은 무엇인가
- 그 테이블에 PK 또는 `NOT NULL` UNIQUE 키가 있는가
- `COUNT_TRANSACTIONS_RETRIES`가 계속 증가하는가
- worker별 transient error가 1205/1213인가
- 수정 row 수보다 보유 lock 수가 훨씬 큰가
- `data_locks`에서 어떤 인덱스에 락이 집중되는가
- blocking transaction이 applier worker인가, 외부 세션인가
- lag 발생 순간 위 결과를 자동 저장하고 있는가

새 테이블에서 PK 누락을 막을 수 있다면 `sql_require_primary_key=ON`도 검토할 수 있다. 기존 애플리케이션과 복제 토폴로지에 미치는 영향을 먼저 확인해야 한다.

## 남는 기준

이 장애에서 가장 헷갈렸던 부분은 source의 UPDATE가 빠르고 Replica의 CPU와 IOPS도 낮았다는 점이었다. 하지만 row-based replication에서 source의 실행 계획은 Replica의 실행 경로가 아니다. Replica는 row event를 적용하기 위해 변경 대상을 자기 테이블에서 다시 찾아야 한다.

**수정되는 테이블에 PK 또는 모든 컬럼이 `NOT NULL`인 UNIQUE 키가 있는가. applier가 수정 row보다 훨씬 많은 lock을 잡고 있는가.**

CPU와 IOPS가 조용한 Replica lag를 만났다면 이 두 질문부터 확인한다.

## 참고자료

- [MySQL Reference Manual — Replication and Row Searches](https://dev.mysql.com/doc/refman/8.4/en/replication-features-row-searches.html)
- [MySQL Reference Manual — Replication Retries and Timeouts](https://dev.mysql.com/doc/refman/8.4/en/replication-features-timeout.html)
- [MySQL Reference Manual — replication_applier_status_by_worker](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-replication-applier-status-by-worker-table.html)
- [MySQL Reference Manual — data_locks Table](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-data-locks-table.html)
- [MySQL Reference Manual — Clustered and Secondary Indexes](https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html)
- [MySQL Reference Manual — Partitioning Keys and Unique Keys](https://dev.mysql.com/doc/refman/8.4/en/partitioning-limitations-partitioning-keys-unique-keys.html)

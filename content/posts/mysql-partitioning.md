---
title: "MySQL 파티셔닝은 언제 도움이 될까"
url: "/database/mysql/2026/01/23/mysql-partitioning/"
date: 2026-01-23 20:00:00 +0900
categories: [database, mysql]
---

테이블이 커졌다고 바로 파티셔닝을 넣으면 안 된다. MySQL 파티셔닝은 만능 성능 기능이 아니다. 쿼리가 파티션 키로 잘 잘리고, 오래된 데이터를 파티션 단위로 관리해야 할 때 효과가 난다.

수천만 건 이하에서 단순 조회가 느리다면 보통은 인덱스, 쿼리, buffer pool, 통계가 먼저다.

## 파티셔닝이 하는 일

파티셔닝은 하나의 논리 테이블을 여러 물리 조각으로 나눠 저장한다.

```text
orders
  p2024
  p2025
  p2026
```

사용자는 `orders` 하나를 조회하지만, 옵티마이저는 조건에 따라 필요한 파티션만 읽을 수 있다. 이를 partition pruning이라고 한다.

```sql
SELECT *
FROM orders
WHERE order_date >= '2026-01-01'
  AND order_date <  '2026-02-01';
```

`order_date`로 RANGE 파티셔닝되어 있다면 해당 월 또는 연도 파티션만 읽는다. 반대로 조건에 파티션 키가 없으면 모든 파티션을 읽는다.

## 효과가 나는 경우

| 상황 | 이유 |
|---|---|
| 날짜 기준으로 오래된 데이터를 자주 삭제 | `DROP PARTITION`이 대량 `DELETE`보다 훨씬 싸다 |
| 대부분의 쿼리가 파티션 키를 조건에 포함 | pruning으로 읽는 범위가 줄어든다 |
| 운영상 데이터 생명주기가 명확함 | 월별, 일별 보관 정책을 테이블 구조로 표현 가능 |

로그, 이벤트, 주문 이력처럼 시간 축으로 계속 쌓이고 오래된 범위를 통째로 지우는 데이터가 대표적이다.

## 효과가 약한 경우

| 상황 | 문제 |
|---|---|
| WHERE에 파티션 키가 없음 | 모든 파티션 스캔 |
| PK/Unique 제약과 파티션 키가 안 맞음 | 테이블 설계부터 막힘 |
| FK가 필요함 | MySQL 파티셔닝 제약과 충돌 |
| 작은 테이블 | 관리 비용만 늘어남 |
| 파티션 수가 과도함 | 메타데이터와 운영 부담 증가 |

특히 MySQL에서는 파티션 키가 모든 unique key에 포함되어야 한다. 전역 unique index가 없기 때문에, MySQL이 전체 파티션을 뒤지지 않고 유일성을 보장하려면 파티션 키가 필요하다.

```sql
CREATE TABLE orders (
    id BIGINT NOT NULL,
    order_date DATE NOT NULL,
    amount DECIMAL(10, 2),
    PRIMARY KEY (id, order_date)
)
PARTITION BY RANGE COLUMNS(order_date) (
    PARTITION p202601 VALUES LESS THAN ('2026-02-01'),
    PARTITION p202602 VALUES LESS THAN ('2026-03-01'),
    PARTITION pmax VALUES LESS THAN (MAXVALUE)
);
```

`PRIMARY KEY (id)`만 두고 `order_date`로 파티셔닝하려 하면 제약에 걸린다.

## 운영에서 보는 지점

파티셔닝의 장점은 조회보다 삭제와 보관 정책에서 더 선명할 때가 많다.

```sql
ALTER TABLE orders DROP PARTITION p202401;
```

한 달치 데이터를 `DELETE`로 지우면 undo, redo, lock, replication lag를 신경 써야 한다. 파티션 삭제는 해당 파티션을 통째로 제거하므로 훨씬 단순하다. 대신 되돌리기도 어렵다. 백업과 보관 정책이 먼저 정리되어 있어야 한다.

새 파티션을 미리 만들지 않으면 `pmax`에 데이터가 몰릴 수 있다. RANGE 파티셔닝은 파티션 생성 작업이 운영 캘린더에 들어가야 한다.

```sql
ALTER TABLE orders REORGANIZE PARTITION pmax INTO (
    PARTITION p202603 VALUES LESS THAN ('2026-04-01'),
    PARTITION pmax VALUES LESS THAN (MAXVALUE)
);
```

## 도입 전 질문

- 느린 쿼리의 WHERE 절에 파티션 키가 항상 들어가는가?
- `EXPLAIN PARTITIONS`에서 실제로 pruning이 되는가?
- 오래된 데이터를 파티션 단위로 지우는 요구가 있는가?
- 모든 unique key에 파티션 키를 포함할 수 있는가?
- FK를 포기하거나 애플리케이션에서 보완할 수 있는가?
- 파티션 생성, 삭제, 백업, 복구 절차가 운영에 들어갈 수 있는가?

이 질문에 답하지 못하면 파티셔닝은 성능 개선이 아니라 복잡도 증가가 될 가능성이 높다.

## 참고자료

- [MySQL Partitioning](https://dev.mysql.com/doc/refman/8.0/en/partitioning.html)
- [MySQL Partition Pruning](https://dev.mysql.com/doc/refman/8.0/en/partitioning-pruning.html)
- [MySQL Partitioning Limitations](https://dev.mysql.com/doc/refman/8.0/en/partitioning-limitations.html)

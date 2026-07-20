---
title: "MySQL Replica에서 UPDATE가 느리다면 PK 또는 UNIQUE 키부터 본다"
url: "/backend/mysql/2026/07/20/mysql-replica-update-primary-key/"
date: 2026-07-20 18:00:00 +0900
categories: [backend, mysql]
---

Replica 지연이 발생했을 때 source의 느린 쿼리나 Replica의 CPU만 먼저 봤다. 원인은 UPDATE가 실행되는 테이블에 PK나 `NOT NULL` UNIQUE 키가 없었던 것이었다.

source에서는 조건에 맞는 row를 찾아 UPDATE하면 끝난다. 하지만 row-based replication을 사용하는 Replica는 relay log의 row event를 적용하면서 **어느 row를 바꿔야 하는지 자기 테이블에서 다시 찾아야 한다.** 이때 PK 또는 적절한 UNIQUE 키가 없으면 대상 테이블을 훑게 되고, UPDATE가 쌓일수록 replica lag가 커질 수 있다.

그래서 Replica를 쓰는 환경에서 UPDATE 또는 DELETE가 일어나는 테이블은 PK를 기본으로 두고, PK가 불가능하다면 모든 컬럼이 `NOT NULL`인 UNIQUE 키를 둬야 한다.

## Replica는 UPDATE 문을 그대로 실행하지 않을 수 있다

예를 들어 source에서 다음 쿼리가 실행됐다고 하자.

```sql
UPDATE notification_delivery
SET sent_at = NOW(), status = 'sent'
WHERE provider_message_id = 'abc-123';
```

`binlog_format=ROW`이면 binlog에는 이 SQL 문자열이 아니라, 변경 전과 변경 후 row 이미지가 기록된다. Replica의 applier는 그 row 이미지를 받아 `notification_delivery`에서 일치하는 row를 찾은 뒤 변경을 적용한다.

```text
source:  UPDATE 실행 → row event 기록
replica: row event 수신 → 대상 row 탐색 → UPDATE 적용
```

여기서 탐색 방법이 중요하다.

| Replica 테이블의 키 | row 탐색 방식 | UPDATE 1건의 비용 |
|---|---|---|
| PK | PK index lookup | 작음 |
| 모든 컬럼이 `NOT NULL`인 UNIQUE 키 | unique index lookup | 작음 |
| 일반 index 또는 NULL을 포함한 UNIQUE 키 | index를 훑으며 대조 | 테이블 크기에 비례할 수 있음 |
| index 없음 | table scan | 테이블 크기에 비례 |

PK나 `NOT NULL` UNIQUE 키가 있으면 Replica는 한 row를 바로 찾는다. 없으면 row event의 before image와 테이블 row를 대조해야 한다. 큰 테이블에서 이런 UPDATE가 반복되면 source는 멀쩡한데 Replica의 SQL/applier thread만 따라가지 못하는 상황이 생긴다.

## 실제로 문제가 되는 테이블

문제가 된 형태는 대략 이랬다.

```sql
CREATE TABLE notification_delivery (
    provider_message_id VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL,
    sent_at DATETIME NULL,
    payload JSON NOT NULL,
    created_at DATETIME NOT NULL
) ENGINE=InnoDB;
```

애플리케이션은 `provider_message_id`가 사실상 하나의 row를 가리킨다고 믿고 UPDATE했다. 그러나 DB 제약으로는 그 사실이 표현되어 있지 않았다. Replica 입장에서는 빠르게 한 row를 식별할 방법이 없었다.

가장 작은 수정은 업무적으로 유일한 값을 UNIQUE 키로 만드는 것이다.

```sql
ALTER TABLE notification_delivery
ADD CONSTRAINT uk_notification_delivery_provider_message_id
UNIQUE (provider_message_id);
```

새 테이블이라면 보통은 surrogate PK를 둔다.

```sql
CREATE TABLE notification_delivery (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    provider_message_id VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL,
    sent_at DATETIME NULL,
    payload JSON NOT NULL,
    created_at DATETIME NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_provider_message_id (provider_message_id)
) ENGINE=InnoDB;
```

PK는 복제 적용을 위한 빠른 식별자이고, `provider_message_id`의 UNIQUE 키는 중복 데이터도 막고 애플리케이션의 조회·수정 조건도 지원한다. 둘 중 하나만 있어도 Replica의 row 탐색에는 도움이 되지만, 도메인상 유일해야 하는 값은 UNIQUE 제약으로도 표현하는 편이 안전하다.

## UNIQUE 키에도 조건이 있다

Replica가 PK 다음으로 우선 선택하는 것은 **모든 컬럼이 `NOT NULL`인 UNIQUE 키**다.

```sql
-- Replica의 row 식별에 적합
provider_message_id VARCHAR(100) NOT NULL UNIQUE

-- NULL을 여러 개 허용하므로 같은 수준의 식별자가 아님
provider_message_id VARCHAR(100) NULL UNIQUE
```

MySQL의 UNIQUE 키는 `NULL`을 여러 개 허용한다. 따라서 nullable UNIQUE 키는 "이 값으로 정확히 한 row를 찾는다"는 보장을 주지 못한다. Replica의 빠른 row lookup을 기대한다면 UNIQUE 키의 구성 컬럼을 `NOT NULL`로 둔다.

복합 UNIQUE 키도 모든 컬럼이 `NOT NULL`이어야 한다.

```sql
UNIQUE KEY uk_tenant_external_id (tenant_id, external_id)
```

이 경우 `tenant_id`, `external_id` 모두 `NOT NULL`이어야 한다.

## 먼저 확인할 것

지연이 난다고 바로 키를 추가하기보다, 해당 테이블이 실제로 row-based replication에서 UPDATE/DELETE되는지 확인한다.

```sql
SHOW VARIABLES LIKE 'binlog_format';
SHOW REPLICA STATUS\G
SHOW CREATE TABLE notification_delivery\G
```

스키마에서 PK가 없는 테이블은 다음처럼 찾을 수 있다.

```sql
SELECT t.table_schema, t.table_name
FROM information_schema.tables AS t
LEFT JOIN information_schema.table_constraints AS c
  ON c.table_schema = t.table_schema
 AND c.table_name = t.table_name
 AND c.constraint_type = 'PRIMARY KEY'
WHERE t.table_type = 'BASE TABLE'
  AND t.table_schema NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
  AND c.constraint_name IS NULL;
```

이 목록 전체가 문제라는 뜻은 아니다. INSERT만 하는 로그성 테이블과 UPDATE/DELETE가 발생하는 테이블을 구분해야 한다. 하지만 Replica 지연이 있고 UPDATE가 있는 테이블이라면, PK와 `NOT NULL` UNIQUE 키가 있는지를 가장 먼저 확인할 만하다.

## 키 추가 전 운영 주의점

큰 테이블에 PK나 UNIQUE 인덱스를 추가하는 DDL은 자체로 비용이 크고, 쓰기 부하와 메타데이터 락 영향을 받을 수 있다. 운영 환경에서는 대상 row 수, 중복 데이터, 사용 중인 MySQL 버전과 online DDL 가능 범위를 먼저 확인해야 한다.

특히 UNIQUE 키를 추가하기 전에는 중복이 없는지 확인한다.

```sql
SELECT provider_message_id, COUNT(*)
FROM notification_delivery
GROUP BY provider_message_id
HAVING COUNT(*) > 1;
```

중복을 정리하지 않고 UNIQUE 키를 추가하면 DDL이 실패한다. 데이터 정리와 인덱스 추가는 별도 작업으로 계획하는 편이 안전하다.

## 남는 기준

Replica의 지연은 네트워크나 서버 사양 문제만은 아니다. row-based replication에서 UPDATE와 DELETE는 Replica가 변경 대상을 찾는 작업까지 포함한다.

**수정되는 테이블에 PK 또는 모든 컬럼이 `NOT NULL`인 UNIQUE 키가 있는가.** Replica lag가 생겼을 때 이 질문을 먼저 확인한다.

## 참고자료

- [MySQL Reference Manual — Replication and Row Searches](https://dev.mysql.com/doc/refman/8.4/en/replication-features-row-searches.html)
- [MySQL Reference Manual — Replication Applier Status Tables](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-replication-applier-status-tables.html)

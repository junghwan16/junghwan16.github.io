---
title: "InnoDB에서 Primary Key는 왜 row의 주소가 되는가"
url: "/backend/mysql/2026/07/18/innodb-primary-key-clustered-index/"
date: 2026-07-18 18:00:00 +0900
categories: [backend, mysql]
---

[앞 글](/backend/mysql/2026/07/17/mysql-row-based-replication/)에서는 Row-based replication의 UPDATE가 before image로 기존 row를 다시 찾는다는 점을 살펴봤다. 이제 InnoDB가 row와 인덱스를 어떻게 저장하는지 보자.

**이번 글에서 이해할 한 문장:** InnoDB의 table row는 clustered index에 저장되며, 보통 Primary Key가 그 clustered index다.

## Primary Key부터 다시 보기

Primary Key, 줄여서 PK는 테이블에서 각 row를 하나로 식별하는 컬럼 또는 컬럼 조합이다.

```sql
CREATE TABLE users (
    id BIGINT NOT NULL PRIMARY KEY,
    name VARCHAR(100) NOT NULL
);
```

`id=1`인 사용자는 한 명만 존재하며 `id`는 `NULL`일 수 없다. 그래서 다음 질문에 답할 수 있다.

> users 테이블의 여러 row 중 정확히 어느 row인가?

```sql
SELECT * FROM users WHERE id = 1;
```

UNIQUE 인덱스도 중복을 막지만 nullable 컬럼에는 여러 `NULL`이 들어갈 수 있다. 그래서 복제의 row 식별 키로 쓰려면 모든 구성 컬럼이 `NOT NULL`이어야 한다.

## row와 PK가 따로 있지 않다

보통 인덱스를 책 뒤의 찾아보기처럼 설명한다. 인덱스에서 위치를 찾고, 별도로 저장된 본문으로 이동한다는 비유다.

InnoDB의 Primary Key는 조금 다르다. Primary Key 인덱스의 맨 아래 단계에 row 데이터가 함께 저장된다. 이를 **clustered index**라고 한다.

`B-Tree`와 `leaf page`를 아직 배우지 않았다면 “정렬된 인덱스 구조의 마지막 칸에 실제 row가 함께 있다”고 이해하면 충분하다.

```text
Primary Key B-Tree

          [5000]
         /      \
 [1000 ... 4999] [5000 ... 9999]
         ↓
leaf record: PK + 나머지 row 컬럼
```

그래서 PK로 찾는 일은 “인덱스에서 주소를 얻고 다른 heap 파일로 이동”하는 과정이 아니다. clustered index의 leaf record에 도착하면 row 데이터도 함께 만난다.

## InnoDB가 clustered index를 고르는 순서

InnoDB table에는 항상 clustered index가 하나 있다. 선택 순서는 다음과 같다.

1. 명시한 `PRIMARY KEY`
2. PK가 없으면 모든 컬럼이 `NOT NULL`인 첫 번째 UNIQUE 인덱스
3. 둘 다 없으면 InnoDB가 숨은 row ID와 `GEN_CLUST_INDEX` 생성

예를 들어 다음 테이블에는 명시적인 PK가 없다.

```sql
CREATE TABLE coupon_issue_history (
    campaign_id BIGINT UNSIGNED NOT NULL,
    user_id BIGINT UNSIGNED NOT NULL,
    issue_token VARCHAR(64) NOT NULL,
    status VARCHAR(20) NOT NULL,
    requested_at DATETIME NOT NULL,
    KEY idx_requested_at (requested_at)
) ENGINE=InnoDB;
```

InnoDB는 row를 저장해야 하므로 내부적으로 6-byte row ID를 만들고 `GEN_CLUST_INDEX`에 row를 배치한다.

```text
명시적 PK 없음
적절한 UNIQUE NOT NULL 인덱스 없음
  ↓
숨은 row ID 생성
  ↓
GEN_CLUST_INDEX가 clustered index가 됨
```

## 숨은 row ID가 있는데 왜 문제가 될까

`GEN_CLUST_INDEX` 덕분에 InnoDB 자체는 row를 저장할 수 있다. 하지만 애플리케이션과 replication event에는 이 숨은 row ID가 노출되지 않는다.

Row-based replication의 applier는 before image에 들어 있는 테이블 컬럼으로 row를 찾아야 한다. 숨은 인덱스는 row search 후보에서 제외된다. 따라서 “InnoDB 내부에는 row ID가 있으니 Replica도 빠르게 찾겠지”라는 기대는 성립하지 않는다.

```text
InnoDB 내부: 숨은 row ID를 알고 있음
binlog row event: 숨은 row ID가 없음
Replica applier: 그 ID로 검색할 수 없음
```

명시적인 PK는 schema에도 있고 before image에도 포함될 수 있으므로 applier가 point lookup에 사용할 수 있다.

## secondary index에는 PK가 들어 있다

PK 이외의 인덱스를 secondary index라고 한다.

```sql
KEY idx_user_requested (user_id, requested_at)
```

InnoDB의 secondary index leaf record에는 선언한 인덱스 컬럼뿐 아니라 해당 row의 Primary Key 값도 저장된다.

```text
idx_user_requested leaf record

(user_id, requested_at, primary_key)
```

secondary index에서 조건에 맞는 record를 찾으면, 함께 저장된 PK로 clustered index의 실제 row를 찾는다.

```text
secondary index 검색
  ↓
leaf record에서 PK 확인
  ↓
clustered index를 PK로 다시 검색
  ↓
row 데이터 접근
```

이 구조 때문에 PK는 짧을수록 유리하다. 긴 자연키를 PK로 만들면 그 값이 모든 secondary index record에 반복 저장된다.

## 자연키와 surrogate key

쿠폰 발급 이력에서 다음 조합을 자연키 후보로 생각할 수 있다.

```sql
UNIQUE (issue_token, requested_at)
```

그러나 네트워크 재시도를 별도 이력으로 보관한다면 같은 값이 여러 번 들어올 수 있다. 이미 중복이 있으면 UNIQUE 추가가 실패하고, 앞으로 허용하던 INSERT도 duplicate key error가 된다.

업무 데이터의 유일성을 자신 있게 보장하기 어렵다면 짧은 surrogate key가 단순하다.

```sql
id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY
```

surrogate key는 업무 의미를 표현하지 않는다. 대신 각 row에 짧고 변하지 않는 주소를 준다. 업무 중복을 금지해야 한다면 그 규칙은 별도의 UNIQUE 인덱스로 표현할 수 있다.

## 파티션 테이블에서는 한 가지 제약이 더 있다

MySQL 파티션 테이블의 모든 UNIQUE 키는 파티션 표현식에 사용한 컬럼을 포함해야 한다.

```sql
PARTITION BY RANGE COLUMNS(requested_at) (...)
```

이 테이블에서 PK를 추가한다면 `requested_at`도 포함해야 한다.

```sql
PRIMARY KEY (id, requested_at)
```

이는 모든 테이블의 일반 규칙이 아니라 MySQL 파티션 테이블의 제약이다. 파티션이 없다면 보통 `PRIMARY KEY (id)`면 충분하다.

## 실제 테이블에서 확인하는 방법

먼저 DDL을 본다.

```sql
SHOW CREATE TABLE app.coupon_issue_history\G
```

스키마에서 PK 없는 테이블을 찾을 수도 있다.

```sql
SELECT t.table_schema, t.table_name, t.table_rows
FROM information_schema.tables AS t
LEFT JOIN information_schema.table_constraints AS c
  ON c.table_schema = t.table_schema
 AND c.table_name = t.table_name
 AND c.constraint_type = 'PRIMARY KEY'
WHERE t.table_type = 'BASE TABLE'
  AND t.table_schema NOT IN (
      'mysql', 'sys', 'performance_schema', 'information_schema'
  )
  AND c.constraint_name IS NULL
ORDER BY t.table_rows DESC;
```

목록이 나왔다고 전부 즉시 장애인 것은 아니다. UPDATE와 DELETE가 많은 큰 테이블부터 본다. 이 작업들은 기존 row를 찾아야 하기 때문이다.

## 여기까지의 기준

1. InnoDB table의 row는 clustered index에 저장된다.
2. PK가 없으면 `NOT NULL` UNIQUE, 그것도 없으면 숨은 `GEN_CLUST_INDEX`가 clustered index가 된다.
3. 숨은 row ID는 replication row search의 주소로 쓸 수 없다.
4. secondary index에는 PK 값이 함께 저장되므로 PK는 짧을수록 좋다.

다음 글에서는 [일반 인덱스 scan이 왜 수정 row보다 많은 record lock을 만드는지](/backend/mysql/2026/07/19/innodb-lock-amplification/)를 살펴본다.

## 참고자료

- [MySQL Reference Manual — Clustered and Secondary Indexes](https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html)
- [MySQL Reference Manual — Partitioning Keys, Primary Keys, and Unique Keys](https://dev.mysql.com/doc/refman/8.4/en/partitioning-limitations-partitioning-keys-unique-keys.html)
- [MySQL Reference Manual — Replication and Row Searches](https://dev.mysql.com/doc/refman/8.4/en/replication-features-row-searches.html)

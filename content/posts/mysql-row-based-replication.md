---
title: "Row-based replication은 SQL 대신 무엇을 전달하는가"
url: "/backend/mysql/2026/07/17/mysql-row-based-replication/"
date: 2026-07-17 18:00:00 +0900
categories: [backend, mysql]
---

[앞 글](/backend/mysql/2026/07/16/mysql-binlog-basics/)에서는 binlog가 데이터 변경을 재현하기 위한 이벤트 기록이라는 점을 살펴봤다. 이제 `binlog_format=ROW`일 때 실제로 무엇이 기록되는지 보자.

**이번 글에서 이해할 한 문장:** Row-based replication에서 Replica는 source의 원래 UPDATE 문을 실행하지 않고, **변경 전 row를 찾아 변경 후 값으로 바꾼다.**

여기서 row는 테이블의 한 행이다. 다음 표에서는 `(17, 42001, 'pending')` 한 줄 전체가 row 하나다.

```text
campaign_id | user_id | status
------------+---------+--------
17          | 42001   | pending
```

## 같은 결과를 전달하는 두 방법

쿠폰 발급 요청을 만료시키는 쿼리가 있다.

```sql
UPDATE coupon_issue_history
SET status = 'expired', updated_at = NOW()
WHERE campaign_id = 17
  AND status = 'pending'
  AND requested_at < NOW() - INTERVAL 5 MINUTE
ORDER BY requested_at
LIMIT 20;
```

Statement-based replication이라면 이 SQL 문을 binlog에 기록하고 Replica가 다시 실행한다.

```text
source:  UPDATE 문 실행
binlog:  UPDATE 문 기록
replica: 같은 UPDATE 문 실행
```

Row-based replication은 다르다. source가 실제로 바꾼 row의 정보를 이벤트로 기록한다.

```text
source:  UPDATE 문 실행
binlog:  "이 row가 이렇게 바뀌었다"는 이벤트 기록
replica: 변경 전 row를 찾아 변경 후 값 적용
```

source에서 UPDATE가 어떤 인덱스를 사용했는지는 Replica에 전달되지 않는다.

## before image와 after image

row update event에는 변경 전과 변경 후 정보가 있다.

- **before image**: 변경할 row를 Replica에서 찾는 데 사용하는 값
- **after image**: 찾은 row에 적용할 새로운 값

사진의 “수정 전/수정 후”를 떠올리면 쉽다.

```text
before image                  after image

user_id | status             user_id | status
--------+---------           --------+--------
42001   | pending     →      42001   | expired
```

`mysqlbinlog -vv`로 디코딩하면 다음처럼 보인다.

```text
### UPDATE `app`.`coupon_issue_history`
### WHERE
###   @1=17
###   @2=42001
###   @3='coupon-001'
###   @4='pending'
### SET
###   @1=17
###   @2=42001
###   @3='coupon-001'
###   @4='expired'
```

이 출력의 `WHERE`는 애플리케이션이 실행한 원래 WHERE 절이 아니다. `mysqlbinlog`가 before image를 SQL처럼 읽기 좋게 표현했을 뿐이다.

실제 원문은 캠페인과 상태, 시각 범위로 20건을 찾았지만 디코딩 결과에는 개별 row의 값이 나온다. 이 차이를 놓치면 “source에서 사용한 좋은 인덱스를 Replica도 사용하겠지”라고 잘못 생각하게 된다.

## INSERT, UPDATE, DELETE는 필요한 정보가 다르다

세 연산을 비교하면 row search가 왜 UPDATE와 DELETE에서 문제가 되는지 보인다.

| 연산 | Replica가 해야 하는 일 |
|---|---|
| INSERT | after image로 새 row를 추가한다 |
| UPDATE | before image와 일치하는 기존 row를 찾아 after image를 적용한다 |
| DELETE | before image와 일치하는 기존 row를 찾아 삭제한다 |

INSERT는 기존 row를 찾을 필요가 없다. UPDATE와 DELETE는 반드시 “어느 row인가”를 먼저 해결해야 한다.

그래서 PK 없는 큰 테이블이 모두 똑같이 위험한 것은 아니다. INSERT만 쌓이는 테이블보다 UPDATE와 DELETE가 자주 발생하는 테이블에서 Replica row search 비용이 먼저 드러난다.

## Replica는 어떤 인덱스를 선택할까

MySQL 8.4의 row search 우선순위는 다음과 같다.

1. Primary Key
2. 모든 컬럼이 `NOT NULL`인 UNIQUE 인덱스
3. 그 밖의 사용 가능한 인덱스
4. 적절한 인덱스가 없으면 table scan

PK 또는 `NOT NULL` UNIQUE 키가 있으면 이벤트의 각 row를 **point lookup**할 수 있다. point lookup은 책의 모든 페이지를 넘기지 않고 학번이나 주민번호처럼 유일한 값으로 한 대상을 바로 찾는 검색이다.

```text
before image의 PK = 93012
  ↓
PK 인덱스에서 93012 검색
  ↓
한 row를 찾아 변경
```

일반 인덱스만 있다면 이야기가 달라진다. 일반 인덱스는 같은 값을 가진 row가 여러 개일 수 있어 후보를 하나씩 확인해야 한다.

MySQL 내부 구현은 row event의 before image들로 hash table을 만들고, 선택한 일반 인덱스를 따라 대상 테이블의 record를 순회하며 같은 row인지 비교한다. `hash table`이라는 자료구조를 몰라도 괜찮다. 여기서는 “찾아야 할 row 목록을 메모리에 만들어 두고, 테이블의 후보와 하나씩 대조한다”는 뜻이다. 일반 인덱스도 없다면 table scan을 한다.

```text
row event의 before image들을 hash table에 저장
  ↓
Replica 테이블의 record를 순회
  ↓
각 record가 hash table에 있는지 비교
  ↓
일치하면 UPDATE하고 hash table에서 제거
```

일반 인덱스가 있다고 point lookup이 되는 것은 아니다. **유일성을 보장하는 식별 키인가**가 중요하다.

## nullable UNIQUE는 왜 부족한가

MySQL UNIQUE 인덱스는 `NULL`을 여러 개 허용한다.

```sql
CREATE UNIQUE INDEX uk_example
ON coupon_issue_history (external_id, deleted_at);
```

`deleted_at`이 nullable이면 같은 `external_id`에 `deleted_at=NULL`인 row가 여러 개 존재할 수 있다. 따라서 이 인덱스는 “반드시 한 row만 가리키는 주소”가 아니다.

Replica row search에서 unique lookup 후보가 되려면 복합 인덱스의 모든 컬럼이 `NOT NULL`이어야 한다.

## binlog_row_image도 인덱스 선택에 영향을 준다

현재 설정은 다음처럼 확인한다.

```sql
SHOW GLOBAL VARIABLES
WHERE variable_name IN ('binlog_format', 'binlog_row_image');
```

`binlog_row_image`는 row event에 어느 컬럼까지 기록할지 결정한다. Replica는 before image에 인덱스의 모든 컬럼이 있을 때만 그 인덱스를 row search 후보로 사용할 수 있다.

따라서 “Replica 테이블에 인덱스가 있다”만으로는 충분하지 않다.

1. 그 인덱스가 PK 또는 `NOT NULL` UNIQUE인가
2. before image에 인덱스 컬럼이 모두 있는가

두 조건을 함께 봐야 한다.

## source에서 빨랐는데 Replica에서 느릴 수 있는 이유

이제 다음 상황이 모순이 아님을 알 수 있다.

```text
source
  idx_campaign_status_requested로 UPDATE 대상 6건을 빠르게 찾음

Replica
  원래 SQL과 실행 계획을 받지 않음
  before image와 자기 테이블의 키만으로 6건을 다시 찾음
```

source의 SQL 실행 시간이 10ms였다는 사실은 Replica의 row search도 10ms라는 뜻이 아니다. 두 서버는 같은 변경 결과를 만들지만, 대상을 찾는 경로는 다를 수 있다.

## 여기까지의 기준

1. RBR은 원래 SQL이 아니라 row 변경 이벤트를 전달한다.
2. UPDATE와 DELETE를 적용하려면 Replica가 before image로 기존 row를 찾아야 한다.
3. PK나 `NOT NULL` UNIQUE 키가 있어야 확실한 point lookup이 된다.

다음 글에서는 [InnoDB가 PK를 clustered index로 저장하는 방식](/backend/mysql/2026/07/18/innodb-primary-key-clustered-index/)을 살펴본다. 그래야 PK가 단순한 제약 조건을 넘어 왜 row의 주소처럼 동작하는지 이해할 수 있다.

## 참고자료

- [MySQL Reference Manual — Replication Formats](https://dev.mysql.com/doc/refman/8.4/en/replication-formats.html)
- [MySQL Reference Manual — Usage of Row-Based Logging and Replication](https://dev.mysql.com/doc/refman/8.4/en/replication-rbr-usage.html)
- [MySQL Reference Manual — Replication and Row Searches](https://dev.mysql.com/doc/refman/8.4/en/replication-features-row-searches.html)

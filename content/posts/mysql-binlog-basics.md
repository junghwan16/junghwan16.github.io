---
title: "MySQL binlog는 무엇을 기록하는가"
url: "/backend/mysql/2026/07/16/mysql-binlog-basics/"
date: 2026-07-16 18:00:00 +0900
categories: [backend, mysql]
---

MySQL Replica lag를 조사하다 보면 가장 먼저 `binlog`라는 단어를 만난다. 이름 때문에 일반 로그 파일처럼 보이지만 역할은 꽤 다르다.

**이번 글에서 이해할 한 문장:** binlog는 “누가 어떤 SELECT를 했는지”가 아니라 **데이터를 다시 같은 상태로 만들 수 있는 변경 이벤트**를 순서대로 기록한다.

이 글은 다음 순서로 이어지는 시리즈의 첫 번째 글이다.

1. **binlog는 무엇인가**
2. [Row-based replication은 SQL 대신 무엇을 전달하는가](/backend/mysql/2026/07/17/mysql-row-based-replication/)
3. [InnoDB에서 PK는 왜 row의 주소가 되는가](/backend/mysql/2026/07/18/innodb-primary-key-clustered-index/)
4. [UPDATE 6건이 왜 1,600개의 lock을 만들까](/backend/mysql/2026/07/19/innodb-lock-amplification/)
5. [CPU는 한가로운데 Replica lag가 늘어난 장애 분석](/backend/mysql/2026/07/20/mysql-replica-update-primary-key/)

## binlog는 변경 일지다

쿠폰 발급 시스템을 생각해 보자. 사용자가 쿠폰을 요청하면 다음 INSERT가 실행된다.

```sql
INSERT INTO coupon_issue_history (
    campaign_id,
    user_id,
    issue_token,
    status,
    requested_at
) VALUES (17, 42001, 'coupon-001', 'pending', NOW());
```

이 작업으로 테이블의 상태가 달라졌다. MySQL은 이런 변경을 binary log, 줄여서 binlog에 이벤트로 남긴다.

binlog의 대표 목적은 두 가지다.

1. **복제**: source의 변경 이벤트를 Replica에 보내 같은 변경을 재현한다.
2. **시점 복구**: 백업을 복원한 뒤, 백업 이후의 이벤트를 다시 적용해 원하는 시점까지 데이터를 복구한다.

반대로 평범한 `SELECT`나 `SHOW`처럼 데이터를 바꾸지 않는 문장은 binlog 대상이 아니다. 모든 쿼리를 보고 싶다면 general query log나 slow query log처럼 다른 로그를 봐야 한다.

| 로그 | 주된 질문 |
|---|---|
| binlog | 데이터를 어떻게 다시 같은 상태로 만들까 |
| error log | 서버와 복제에서 어떤 오류가 났나 |
| slow query log | 어떤 쿼리가 오래 걸렸나 |
| general query log | 서버가 어떤 요청을 받았나 |

## 이름이 binary인 이유

binlog는 사람이 바로 읽는 텍스트 파일이 아니다. MySQL이 정의한 binary event 형식으로 저장된다. 그래서 파일을 `cat`으로 읽기보다 `mysqlbinlog` 도구로 디코딩한다.

먼저 현재 파일 목록과 source가 기록 중인 위치를 볼 수 있다.

```sql
SHOW BINARY LOGS;
SHOW BINARY LOG STATUS;
```

특정 파일을 사람이 읽을 수 있는 형태로 출력하려면 다음처럼 실행한다.

```bash
mysqlbinlog mysql-bin.000123
```

row event의 컬럼 값까지 보고 싶다면 옵션을 더한다.

```bash
mysqlbinlog \
  --base64-output=DECODE-ROWS \
  --verbose \
  mysql-bin.000123
```

운영 로그에는 개인정보나 업무 데이터가 포함될 수 있다. 디코딩한 결과를 공유할 때는 값과 식별자를 먼저 가려야 한다.

## binlog에는 SQL만 들어가는가

그렇지 않다. 기록 형식은 세 가지다.

| `binlog_format` | 기록하는 것 |
|---|---|
| `STATEMENT` | source가 실행한 SQL 문 |
| `ROW` | 각 row가 어떻게 바뀌었는지 나타내는 이벤트 |
| `MIXED` | 상황에 따라 statement와 row 형식을 선택 |

MySQL 8.4의 기본은 `ROW`다. 현재 설정은 다음처럼 확인한다.

```sql
SHOW GLOBAL VARIABLES LIKE 'binlog_format';
```

형식의 차이는 다음 글에서 중요해진다. `ROW` 형식에서는 source가 실행한 UPDATE 문을 Replica가 그대로 실행하지 않는다. 변경 전후 row 정보를 받아 자기 테이블에서 대상을 다시 찾는다.

## source와 Replica 사이에서 이동하는 과정

복제를 아주 단순하게 그리면 다음과 같다.

```text
애플리케이션이 source의 데이터를 변경
  ↓
source가 변경 이벤트를 binlog에 기록
  ↓
Replica receiver thread가 이벤트를 받아 relay log에 저장
  ↓
Replica applier thread가 relay log의 이벤트를 적용
```

receiver와 applier는 역할이 다르다.

- receiver가 멈추면 새 이벤트를 가져오지 못한다.
- applier가 멈추면 이벤트는 받아도 테이블에 반영하지 못한다.

따라서 “Replica가 source에 연결돼 있다”와 “Replica가 변경을 제때 적용한다”는 같은 말이 아니다. receiver는 정상인데 applier만 lock을 기다리면 CPU와 IOPS는 낮아도 lag가 계속 늘 수 있다.

## file position과 GTID는 무엇인가

에러 로그에서 다음과 비슷한 값을 볼 수 있다.

```text
source log mysql-bin.000123, end_log_pos 8989898
transaction 3E11FA47-71CA-11E1-9E33-C80AA9429562:1042
```

- **file + position**은 어느 binlog 파일의 어디까지 처리했는지를 나타낸다.
- **GTID**는 복제 토폴로지 전체에서 트랜잭션을 식별하는 값이다.

장애 조사에서는 에러 로그의 GTID나 position을 이용해 `mysqlbinlog`에서 실패한 이벤트를 찾는다. 지금은 둘 다 “문제 트랜잭션으로 돌아가는 좌표”라고 이해하면 충분하다.

## 여기까지의 기준

binlog를 “쿼리 로그”라고 기억하면 다음 단계에서 혼란이 생긴다. 다음 세 문장만 남기면 된다.

1. binlog는 데이터 변경을 재현하기 위한 이벤트 기록이다.
2. 복제와 시점 복구가 대표적인 사용처다.
3. `ROW` 형식이라면 원래 SQL이 아니라 row 변경 이벤트가 기록된다.

다음 글에서는 [Row-based replication이 SQL 대신 전달하는 before image와 after image](/backend/mysql/2026/07/17/mysql-row-based-replication/)를 살펴본다.

## 참고자료

- [MySQL Reference Manual — The Binary Log](https://dev.mysql.com/doc/refman/8.4/en/binary-log.html)
- [MySQL Reference Manual — Replication Formats](https://dev.mysql.com/doc/refman/8.4/en/replication-formats.html)

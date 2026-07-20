---
title: "MySQL 복제는 무엇이고 Replica lag는 왜 생길까"
url: "/backend/mysql/2026/07/15/mysql-replication-basics/"
date: 2026-07-15 18:00:00 +0900
categories: [backend, mysql]
---

백엔드 애플리케이션이 처음에는 MySQL 서버 한 대만 사용한다고 하자.

```text
애플리케이션 → MySQL 한 대
```

사용자가 늘어나 읽기 요청이 많아지면 같은 데이터를 가진 MySQL 서버를 한 대 더 두고 일부 SELECT를 맡길 수 있다.

```text
                         ┌→ source: INSERT, UPDATE, DELETE
애플리케이션 ────────────┤
                         └→ Replica: 주로 SELECT
```

source의 변경을 다른 서버에 계속 복사하는 기능이 **replication**, 즉 복제다.

**이번 글에서 이해할 한 문장:** Replica는 source의 디스크를 실시간으로 복사하는 서버가 아니라, **source에서 일어난 데이터 변경을 전달받아 차례로 다시 적용하는 서버**다.

이 글은 MySQL 복제 지연을 기초부터 따라가는 시리즈의 첫 번째 글이다.

1. **MySQL 복제와 Replica lag**
2. [binlog는 무엇을 기록하는가](/backend/mysql/2026/07/16/mysql-binlog-basics/)
3. [Row-based replication은 SQL 대신 무엇을 전달하는가](/backend/mysql/2026/07/17/mysql-row-based-replication/)
4. [InnoDB에서 PK는 왜 row의 주소가 되는가](/backend/mysql/2026/07/18/innodb-primary-key-clustered-index/)
5. [UPDATE 6건이 왜 1,600개의 lock을 만들까](/backend/mysql/2026/07/19/innodb-lock-amplification/)
6. [CPU는 한가로운데 Replica lag가 늘어난 장애 분석](/backend/mysql/2026/07/20/mysql-replica-update-primary-key/)

## source와 Replica

복제에서 원본 변경이 시작되는 서버를 **source**, 그 변경을 받아 적용하는 서버를 **Replica**라고 부른다.

쿠폰 발급 시스템을 예로 들어 보자.

```sql
INSERT INTO coupon_issue_history (
    user_id,
    status
) VALUES (42001, 'pending');
```

애플리케이션이 이 INSERT를 source에서 실행한다. 이후 MySQL 복제 기능이 “새 row가 추가됐다”는 변경을 Replica로 전달한다. Replica도 같은 변경을 적용하면 두 서버의 데이터가 같아진다.

```text
source                         Replica

user_id | status              user_id | status
--------+---------            --------+---------
42001   | pending    ─────→   42001   | pending
```

Replica는 보통 읽기 부하를 나누거나 장애 대응 토폴로지를 구성하는 데 사용한다. 다만 Replica가 있다고 백업이 필요 없어지는 것은 아니다. 잘못된 DELETE도 그대로 복제될 수 있기 때문이다.

## 변경은 한 번에 순간 이동하지 않는다

source의 변경이 Replica에 도착해 적용되기까지 여러 단계가 있다.

```text
1. 애플리케이션이 source의 데이터를 변경
2. source가 변경 내용을 binlog에 기록
3. Replica receiver가 변경 내용을 가져옴
4. Replica가 relay log에 임시 저장
5. Replica applier가 변경을 테이블에 적용
```

아직 모르는 용어가 많아 보여도 괜찮다. 지금은 택배 과정처럼 생각하면 된다.

| 복제 구성 요소 | 택배 비유 | 역할 |
|---|---|---|
| binlog | source의 발송 목록 | source에서 일어난 변경을 순서대로 기록 |
| receiver | 수거 기사 | source에서 변경 이벤트를 가져옴 |
| relay log | Replica의 물류 창고 | 가져온 이벤트를 적용 전까지 보관 |
| applier | 배송 기사 | 이벤트를 Replica 테이블에 실제 반영 |

다음 글부터 각각을 더 정확히 살펴본다. 이 단계에서는 “가져오는 일과 적용하는 일이 분리되어 있다”는 점이 가장 중요하다.

## Replica lag란 무엇인가

source는 10시 00분에 쿠폰 상태를 `issued`로 바꿨는데 Replica에는 10시 00분 05초에 반영됐다고 하자.

```text
10:00:00  source:  pending → issued
10:00:01  Replica: 아직 pending
10:00:05  Replica: issued 적용 완료
```

이 5초 동안 Replica의 데이터는 source보다 뒤처져 있었다. 이렇게 source의 변경을 Replica가 아직 적용하지 못한 지연을 **Replica lag**라고 부른다.

복제가 비동기 방식이라면 아주 짧은 지연은 자연스럽다. 문제는 지연이 줄지 않고 계속 커질 때다.

```text
12초 → 40초 → 2분 → 9분
```

이는 source가 새 변경을 만드는 속도보다 Replica가 적용하는 속도가 느리다는 뜻이다.

## receiver 문제와 applier 문제는 다르다

Replica lag가 생겼을 때 먼저 나눌 질문은 두 가지다.

1. source의 변경을 **가져오지 못하는가?**
2. 가져왔지만 Replica 테이블에 **적용하지 못하는가?**

첫 번째는 receiver 쪽 문제다. 네트워크 단절이나 source 연결 문제가 대표적이다.

두 번째는 applier 쪽 문제다. 적용할 쿼리가 느리거나, lock을 기다리거나, 오류로 thread가 멈출 수 있다.

```text
receiver가 멈춤
source ──X──> relay log ─────> applier

applier가 멈춤
source ─────> relay log ──X──> Replica table
```

applier가 멈춰도 receiver는 이벤트를 계속 가져올 수 있다. 그러면 relay log에는 적용하지 못한 변경이 쌓이고 lag가 증가한다.

## CPU가 낮아도 lag가 생길 수 있다

“Replica가 느리면 CPU나 디스크가 바쁘겠지”라고 생각하기 쉽다. 하지만 applier가 다른 트랜잭션의 lock을 기다리는 중이라면 상황이 다르다.

```text
applier: 일하고 싶지만 lock이 풀리기를 기다림
CPU: 계산하지 않으므로 낮음
IOPS: 디스크 작업도 적으므로 낮음
lag: 새 변경은 계속 들어오므로 증가
```

따라서 낮은 CPU는 “Replica에 문제가 없다”는 증거가 아니다. 단지 CPU가 병목이 아니라는 뜻일 수 있다.

## 가장 먼저 확인하는 명령

복제 상태는 다음 명령으로 확인한다.

```sql
SHOW REPLICA STATUS\G
```

처음에는 모든 필드를 이해할 필요가 없다. 다음 항목부터 본다.

| 항목 | 쉬운 질문 |
|---|---|
| `Replica_IO_Running` | receiver가 source에서 변경을 가져오고 있는가 |
| `Replica_SQL_Running` | applier가 변경을 적용하고 있는가 |
| `Seconds_Behind_Source` | applier가 source 기준으로 얼마나 뒤처졌는지 보여주는 참고값 |
| `Last_IO_Error` | 가져오는 과정에서 마지막 오류는 무엇인가 |
| `Last_SQL_Error` | 적용하는 과정에서 마지막 오류는 무엇인가 |

예를 들어 다음 조합은 “가져오기는 하지만 적용하지 못한다”는 뜻이다.

```text
Replica_IO_Running:  Yes
Replica_SQL_Running: No
Last_SQL_Error:      Lock wait timeout exceeded
```

## 읽기 요청에도 영향이 있다

애플리케이션이 쓰기는 source에 보내고 읽기는 Replica에서 한다면, 방금 변경한 값이 잠시 보이지 않을 수 있다.

```text
사용자: 쿠폰 발급 요청
source: issued로 변경
사용자: 바로 내 쿠폰 목록 조회
Replica: 아직 pending → 오래된 값 응답
```

이를 흔히 replication lag에 의한 stale read라고 부른다. 따라서 모든 SELECT를 무조건 Replica로 보내는 것이 항상 안전한 것은 아니다. “방금 쓴 값을 바로 읽어야 하는가”를 기준으로 읽기 경로를 정해야 한다.

## 여기까지의 기준

다음 네 문장만 이해하면 다음 글로 넘어갈 수 있다.

1. source는 원본 변경이 일어나는 서버다.
2. Replica는 변경을 전달받아 다시 적용하는 서버다.
3. receiver는 변경을 가져오고 applier는 변경을 테이블에 반영한다.
4. applier가 적용을 따라가지 못하면 CPU가 낮아도 Replica lag가 커질 수 있다.

다음 글에서는 이 복제 과정의 출발점인 [MySQL binlog](/backend/mysql/2026/07/16/mysql-binlog-basics/)가 무엇을 기록하는지 살펴본다.

## 참고자료

- [MySQL Reference Manual — Replication Implementation](https://dev.mysql.com/doc/refman/8.4/en/replication-implementation.html)
- [MySQL Reference Manual — SHOW REPLICA STATUS](https://dev.mysql.com/doc/refman/8.4/en/show-replica-status.html)

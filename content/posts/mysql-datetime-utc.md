---
title: "MySQL은 왜 TIMESTAMP 대신 DATETIME에 UTC를 담을까"
url: "/backend/mysql/2026/06/21/mysql-datetime-utc/"
date: 2026-06-21 19:00:00 +0900
categories: [backend, mysql]
---

이름만 보면 시각 저장에는 `TIMESTAMP`가 정답 같다. 그런데 장기 보존되는 절대 시점은 `DATETIME(6)`에 UTC로 저장하라는 권장을 자주 본다. 이건 MySQL 매뉴얼이 시키는 규칙이 아니라 현업에서 굳어진 컨벤션이다. 이름값을 못 하는 타입이 왜 생겼고, 이름이 더 정직한 타입을 두고 왜 컨벤션으로 때우는지, "왜 이게 합리적인가"를 정리한다.

## 두 타입의 실제 의미

`DATETIME`과 `TIMESTAMP`는 둘 다 날짜와 시간을 담지만 타임존 처리 방식이 다르다.

- `DATETIME`은 입력한 값을 그대로 저장한다. UTC로 보정해 보관하지도, 조회할 때 세션 타임존으로 변환하지도 않는다. 타입 안에 "어느 지역인가"라는 정보가 없다.
- `TIMESTAMP`는 현재 세션 `time_zone` 기준으로 UTC로 변환해 저장하고, 조회할 때 다시 세션 `time_zone`으로 변환해 보여준다.

공식 문서의 문장이 핵심을 그대로 말한다.

> MySQL converts `TIMESTAMP` values from the current time zone to UTC for storage, and back from UTC to the current time zone for retrieval. (This does not occur for other types such as `DATETIME`.)

| | DATETIME | TIMESTAMP |
| --- | --- | --- |
| 타임존 변환 | 없음 (리터럴 저장) | 세션 `time_zone` ↔ UTC 자동 변환 |
| 범위 | `1000-01-01` ~ `9999-12-31` | `1970-01-01 00:00:01` ~ `2038-01-19 03:14:07` UTC |
| 저장 크기(기본) | 5바이트 + 소수초 | 4바이트 + 소수초 |
| 같은 row를 다른 세션이 보면 | 항상 같은 값 | 세션마다 다른 값 |

## TIMESTAMP의 두 함정

### 1. 2038년에 끝난다

`TIMESTAMP`의 내부 표현은 부호 있는 32비트 `time_t`다. 부호 있는 32비트 정수의 최댓값 `2^31 - 1 = 2,147,483,647`초를 1970 epoch에 더하면 정확히 `2038-01-19 03:14:07` UTC가 된다. 그 다음 초에 오버플로한다. 이게 [Year 2038 문제](/cs/binary/2026/03/10/twos-complement-overflow/)다.

MySQL `WorkLog #1872`("Add support for dates from 2038 till 2116")은 범위를 넓히려 했지만 상태는 Un-Assigned, 타깃은 폐기된 Server-7.0이었다. 8.0.28부터 `FROM_UNIXTIME()` 같은 *함수*는 64비트를 다루지만, `TIMESTAMP` *타입*의 상한은 여전히 2038년이다. 2026년에 새 시스템을 만든다면 `created_at` 하나도 시스템 수명이 길면 결국 마이그레이션 비용이 된다.

### 2. 값의 의미가 세션 타임존에 묶인다

이쪽이 더 미묘하고 위험하다. `TIMESTAMP`의 표시 값은 그 커넥션의 `time_zone`에 따라 달라진다.

```sql
SET time_zone = '+00:00';
SELECT ts FROM t;   -- 2026-06-21 01:00:00

SET time_zone = 'Asia/Seoul';
SELECT ts FROM t;   -- 2026-06-21 10:00:00  (같은 row, 같은 순간)
```

값이 바뀐 게 아니라 해석이 바뀐 것이다. 문제는 이 변환이 *암묵적*이라는 점이다. 애플리케이션 서버, 커넥션 풀, 리플리카, 분석 도구, 드라이버가 제각기 다른 `time_zone`으로 붙으면 같은 컬럼이 조용히 다른 의미가 된다. 스키마나 쿼리만 봐서는 드러나지 않는다.

## DATETIME + UTC 컨벤션이 주는 것

`DATETIME`은 넣은 값을 그대로 돌려준다. 그래서 "이 컬럼은 UTC instant다"라는 의미를 팀이 정하고 지키면 다음을 얻는다.

- **결정성**: 세션 `time_zone`이 무엇이든 저장·조회 값이 변하지 않는다. 숨은 변환이 없다.
- **범위**: 9999년까지 가므로 2038년 절벽이 없다.
- **단일 소유권**: 타임존 변환 로직을 DB 커넥션 설정이 아니라 애플리케이션 경계 한 곳에 둔다. Django `USE_TZ`, Rails, Hibernate처럼 주류 ORM이 이미 이 방식("UTC로 저장하고 앱에서 변환")을 쓴다.
- **정렬·범위 스캔의 정확성**: UTC는 단조 증가하므로 `ORDER BY`와 range scan이 절대 시점 순서와 일치한다. 로컬 시각을 그대로 담으면 DST 가을 되감기 구간에서 정렬이 깨진다.

## 공짜는 아니다

컨벤션에는 대가가 있다. 정직하게 짚어야 한다.

**`NOW()`는 UTC가 아니다.** `NOW()`와 `CURRENT_TIMESTAMP`는 세션 `time_zone` 기준 로컬 시각을 준다. UTC를 담은 `DATETIME`과 `NOW()`를 그냥 비교하면 틀린다.

```sql
SET time_zone = 'Asia/Seoul';   -- 세션이 KST면 NOW()는 UTC보다 9시간 앞선다
-- created_at은 UTC로 저장돼 있다고 가정

SELECT * FROM events WHERE created_at <= NOW();            -- 9시간 미래까지 포함, 버그
SELECT * FROM events WHERE created_at <= UTC_TIMESTAMP();  -- 올바름
```

**기본값도 세션 로컬이다.** `DEFAULT CURRENT_TIMESTAMP`, `ON UPDATE CURRENT_TIMESTAMP`도 `NOW()`와 같은 세션 로컬 값을 넣는다. 그래서 컬럼이 진짜 UTC가 되려면 커넥션 `time_zone`을 UTC로 고정해야 한다.

```sql
SET time_zone = '+00:00';
```

이렇게 하면 `NOW()`, `UTC_TIMESTAMP()`, `CURRENT_TIMESTAMP` 기본값이 모두 UTC로 일치한다. 즉 **"DATETIME as UTC"의 짝은 "커넥션을 UTC로 고정"**이다. 둘은 같이 가야 컨벤션이 완성된다.

**저장 크기는 TIMESTAMP가 조금 작다.** `DATETIME(6)`은 8바이트, `TIMESTAMP(6)`은 7바이트다. row가 수십억 개면 무시할 수 없다.

| 정밀도 | DATETIME | TIMESTAMP |
| --- | --- | --- |
| `(0)` | 5바이트 | 4바이트 |
| `(3)` | 7바이트 | 6바이트 |
| `(6)` | 8바이트 | 7바이트 |

**편의 기능은 더 이상 TIMESTAMP만의 것이 아니다.** MySQL 5.6.5부터 `DATETIME`도 `DEFAULT CURRENT_TIMESTAMP`와 `ON UPDATE CURRENT_TIMESTAMP`를 지원한다(그 전엔 테이블당 `TIMESTAMP` 컬럼 하나만 가능했다). 자동 갱신 때문에 `TIMESTAMP`를 골라야 할 이유는 사라졌다.

## 그럼 SQL 표준은 어떻게 하라고 하나

사실 SQL 표준에는 이 문제를 위한 타입이 따로 있다. 표준은 `TIMESTAMP`를 둘로 나눈다.

- `TIMESTAMP WITHOUT TIME ZONE`: 타임존 없는 벽시계 값. 변환하지 않는다.
- `TIMESTAMP WITH TIME ZONE`: datetime과 함께 **UTC로부터의 오프셋(displacement)**을 보존한다. 비교는 UTC로 정규화한다. 오프셋이지 `Asia/Seoul` 같은 지역 이름은 아니다. SQL-99 기준 오프셋 범위는 `-12:59` ~ `+13:00`이고, 벤더마다 더 넓혔다.

벤더별로 이 표준을 구현한 방식이 제각각이라, 같은 "TIMESTAMP"라는 이름이 전혀 다르게 동작한다.

| 시스템 | 절대 시점(WITH TIME ZONE) | 벽시계(WITHOUT TIME ZONE) | bare `TIMESTAMP`의 의미 |
| --- | --- | --- | --- |
| SQL 표준 | `TIMESTAMP WITH TIME ZONE` (instant + offset 보존) | `TIMESTAMP` | WITHOUT TIME ZONE |
| PostgreSQL | `timestamptz` (instant만, **offset 버림**) | `timestamp` | WITHOUT TIME ZONE |
| Oracle | `TIMESTAMP WITH TIME ZONE` (offset 또는 지역 이름) / `WITH LOCAL TIME ZONE` | `TIMESTAMP` | WITHOUT TIME ZONE |
| SQL Server | `datetimeoffset` (offset 보존) | `datetime2` | — |
| MySQL | **없음** | `DATETIME` | 세션↔UTC 변환 (`LOCAL TIME ZONE`에 가까움) |

두 가지가 눈에 띈다.

첫째, **MySQL에는 표준의 `WITH TIME ZONE`에 해당하는 타입이 아예 없다.** MySQL `TIMESTAMP`는 표준의 WITH TIME ZONE이 아니라 Oracle의 `TIMESTAMP WITH LOCAL TIME ZONE`(세션 기준 변환)에 가깝다. 그리고 그 하나뿐인 instant 비슷한 타입마저 2038년에서 끝난다. 그래서 "표준 타입을 쓰면 되잖아"가 MySQL에선 선택지가 아니다. 남는 현실적 길이 "DATETIME에 UTC 의미를 부여한다"인 것이다.

둘째, **이름이 가장 안 정직한 게 MySQL이다.** 표준·PostgreSQL·Oracle에서 그냥 `TIMESTAMP`는 변환하지 않는 벽시계 값이다. MySQL만 `TIMESTAMP`가 변환을 한다. 오히려 MySQL의 `DATETIME`이 표준의 WITHOUT TIME ZONE에 해당한다. 타입 이름이 주는 직관과 실제 의미가 어긋나 있다.

## 표준 타입도 은총알은 아니다

그렇다고 표준의 `TIMESTAMP WITH TIME ZONE`이 모든 걸 해결하느냐 하면, 아니다. 이 타입은 offset을 보존하지만 **offset은 지역 이름이 아니다.** 이게 미래의 약속에서 깨진다.

2015년 1월에 "4월 30일 10:00, 칠레" 회의를 잡고 그 시점 규칙(오프셋 −4)으로 instant + offset을 저장했다고 하자. 그런데 칠레가 그 사이 일광절약시간을 폐지해 4월 오프셋이 −3이 됐다. 저장된 절대 시점을 새 규칙으로 되돌리면 11:00이 나온다. 사용자는 1시간 늦는다. DST가 없는 곳도 마찬가지다. 북한은 2015년 표준시를 UTC+9에서 UTC+8:30으로 바꿨다가 2018년 되돌렸다. 순수 정치적 오프셋 변경이다.

핵심은 이거다. **미래의 현지 약속에서 사용자가 의도한 것은 절대 시점이 아니라 벽시계 시각이다.** 그걸 instant로 박제하는 순간, 저장할 때 쓴 규칙과 되돌릴 때 쓴 규칙이 달라지면 어긋난다. 표준이 타입 시스템에 타임존을 넣으려 노력했지만, 그것도 "값의 의미"를 대신 모델링해주진 못한다.

## 그래서 어떻게 저장할까

결론은 타입 이름이 아니라 값의 의미에서 출발한다.

**이미 일어난 절대 시점**(결제 완료, 로그, 이벤트 발생)은 UTC instant로 저장한다. 이미 순간이 고정됐으므로 미래의 규칙 변경이 흔들 수 없다.

- MySQL: `DATETIME(6)` + 커넥션 `time_zone='+00:00'` (또는 `BIGINT` epoch-micros)
- PostgreSQL: `timestamptz`
- 표준/SQL Server: `TIMESTAMP WITH TIME ZONE` / `datetimeoffset`

**미래의 현지 약속**(회의, 알림)은 단일 타입으로 안 된다. 벽시계 시각 + IANA 타임존 이름 + offset(타이브레이커)을 여러 컬럼으로 나눠 저장하고, 표시·발송 직전에 그때의 최신 규칙으로 환산한다.

**날짜·반복 규칙**(생일, 매일 9시)은 `DATE`, `TIME`, 반복 규칙으로 모델링한다.

관통하는 원칙은 하나다. **타임존을 타입에 맡기지 말고 경계로 밀어라.** 저장 계층은 단조적이고 결정적인 UTC instant를 들고, 변환은 애플리케이션 경계에서 명시적으로 한다. MySQL이 `DATETIME`에 UTC를 담는 건 타입이 부족해서이기도 하지만, 동시에 "타입에 타임존 의미를 넣지 않는다"는 더 단순하고 이식성 있는 선택이기도 하다. `TIMESTAMP`의 자동 변환은 편의처럼 보이지만, 그 편의가 곧 값의 의미를 세션 설정에 묶는 비용이다.

## 참고

- [MySQL 8.4 — The DATE, DATETIME, and TIMESTAMP Types](https://dev.mysql.com/doc/refman/8.4/en/datetime.html)
- [MySQL 8.4 — TIMESTAMP and DATETIME Initialization](https://dev.mysql.com/doc/refman/8.4/en/timestamp-initialization.html)
- [MySQL 8.4 — Date and Time Functions](https://dev.mysql.com/doc/refman/8.4/en/date-and-time-functions.html)
- [MySQL 8.4 — Data Type Storage Requirements](https://dev.mysql.com/doc/refman/8.4/en/storage-requirements.html)
- [PostgreSQL — Date/Time Types](https://www.postgresql.org/docs/current/datatype-datetime.html)
- [Oracle — Datetime Data Types and Time Zone Support](https://docs.oracle.com/en/database/oracle/oracle-database/21/nlspg/datetime-data-types-and-time-zone-support.html)
- [SQL Server — datetimeoffset](https://learn.microsoft.com/en-us/sql/t-sql/data-types/datetimeoffset-transact-sql)
- [How to save datetimes for future events](https://www.creativedeletion.com/2015/03/19/persisting_future_datetimes.html)

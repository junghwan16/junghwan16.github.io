---
title: "MySQL filesort: EXPLAIN에 나타났을 때 해야 할 일"
url: "/backend/mysql/2026/04/08/mysql-filesort/"
date: 2026-04-08 18:00:00 +0900
categories: [backend, mysql]
---

> 주문 목록 API가 느려졌다. 슬로우 쿼리 로그를 열어보니 `SELECT * FROM orders WHERE status = 'active' ORDER BY created_at DESC LIMIT 20`이 2초씩 걸린다. `EXPLAIN`을 찍었더니 Extra 컬럼에 `Using filesort`가 있다. 인덱스도 있는데 왜 느린 걸까?

이 글을 읽으면서 "인덱스 leaf에 뭐가 저장돼 있다는 거지?" 싶다면, 먼저 [InnoDB의 Clustered Index와 Secondary Index 구조](/backend/mysql/innodb-clustered-secondary-indexes/)를 읽고 오자. Secondary index가 PK를 들고 있는 구조와 bookmark lookup을 이해하면, 이 글의 인덱스 설계 이야기가 훨씬 자연스럽게 읽힌다.

---

## filesort란 무엇인가

`Using filesort`는 MySQL이 **인덱스 순서만으로 ORDER BY를 처리하지 못해서, 결과를 별도로 정렬**한다는 뜻이다. "file"이라는 이름이 붙어 있지만 항상 디스크를 쓰는 건 아니다. `sort_buffer_size` 안에 들어가면 메모리에서 끝나고, 넘치면 임시 파일을 쓴다.

문제는 row 수가 많을 때다. 10만 건을 정렬해서 20건을 반환하는 건, 처음부터 정렬된 순서로 20건만 읽는 것과 비교할 수 없다.

---

## 왜 발생하는가

인덱스는 **특정 컬럼 순서로 이미 정렬된 B-Tree**다. ORDER BY가 이 순서와 정확히 일치하면 인덱스를 따라 읽기만 하면 된다. 일치하지 않으면 filesort가 발생한다.

구체적으로 보자. `orders` 테이블이 있다:

```sql
CREATE TABLE orders (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  user_id    BIGINT NOT NULL,
  status     VARCHAR(20) NOT NULL,
  created_at DATETIME NOT NULL,
  amount     INT NOT NULL,
  INDEX idx_status (status)
);
```

### Case 1: filesort 발생

```sql
EXPLAIN SELECT * FROM orders
WHERE status = 'active'
ORDER BY created_at DESC
LIMIT 20;
```

```
+----+-------+------------+------+-----------+----------------+
| id | type  | key        | rows | filtered  | Extra          |
+----+-------+------------+------+-----------+----------------+
|  1 | ref   | idx_status | 5000 |    100.00 | Using filesort |
+----+-------+------------+------+-----------+----------------+
```

`idx_status`로 `status = 'active'`인 row 5,000건을 찾았다. 그런데 이 인덱스에는 `created_at` 정보가 없다. MySQL은 5,000건을 모두 읽어서 메모리에서 `created_at DESC`로 정렬한 뒤, 상위 20건을 반환한다.

### Case 2: filesort 회피

```sql
ALTER TABLE orders ADD INDEX idx_status_created (status, created_at);
```

```sql
EXPLAIN SELECT * FROM orders
WHERE status = 'active'
ORDER BY created_at DESC
LIMIT 20;
```

```
+----+-------+--------------------+------+-----------+---------------------+
| id | type  | key                | rows | filtered  | Extra               |
+----+-------+--------------------+------+-----------+---------------------+
|  1 | ref   | idx_status_created |   20 |    100.00 | Backward index scan |
+----+-------+--------------------+------+-----------+---------------------+
```

`(status, created_at)` 복합 인덱스에서 `status = 'active'`인 영역은 이미 `created_at` 순으로 정렬되어 있다. DESC이므로 역방향으로 스캔하면서 20건을 찾는 즉시 멈춘다. 5,000건을 정렬할 필요가 없다.

---

## 핵심 원칙: WHERE 뒤에 ORDER BY

복합 인덱스를 설계할 때, **equality 조건 컬럼을 앞에, ORDER BY 컬럼을 뒤에** 배치한다.

```
인덱스: (equality_col, ..., order_by_col)
```

왜 이 순서여야 하는지 B-Tree 구조로 이해하자:

```
idx_status_created의 leaf page (status, created_at 순으로 정렬됨)

  ('active',  '2026-04-01 09:00')  → id=42
  ('active',  '2026-04-02 14:30')  → id=17
  ('active',  '2026-04-03 08:15')  → id=89   ← 여기서부터 역순으로 20건
  ('closed',  '2026-03-28 11:00')  → id=5
  ('closed',  '2026-04-01 16:45')  → id=33
```

`status = 'active'`로 범위를 좁히면, 그 범위 안에서 `created_at`은 이미 정렬되어 있다. equality 조건이 "같은 값끼리 모아주고", 그 안에서 다음 컬럼이 정렬을 담당하는 것이다.

---

## filesort가 발생하는 흔한 실수들

### 1. 인덱스 컬럼 순서와 ORDER BY 순서 불일치

```sql
-- 인덱스: (status, created_at)
-- 쿼리:
ORDER BY created_at, status   -- ✗ filesort
ORDER BY created_at           -- ✗ filesort (status를 건너뜀)
ORDER BY status, created_at   -- ✓ (하지만 WHERE status = ?가 있으면 ORDER BY created_at만으로 충분)
```

### 2. ASC/DESC 혼합

```sql
-- 인덱스: (a, b)
ORDER BY a ASC, b DESC   -- ✗ filesort (8.0 미만)
```

MySQL 8.0부터는 `CREATE INDEX idx ON t (a ASC, b DESC)` 같은 **DESC index**를 지원한다. 혼합 정렬이 필요하면 인덱스 정의에서 방향을 맞추면 된다.

### 3. range 조건 뒤의 ORDER BY

```sql
-- 인덱스: (created_at, status)
WHERE created_at > '2026-04-01' ORDER BY status   -- ✗ filesort
```

range 조건(`>`, `<`, `BETWEEN`)은 인덱스의 정렬 보장을 **끊는다**. range 조건 컬럼 이후의 컬럼으로는 정렬을 활용할 수 없다. equality 조건을 가능한 한 앞에 배치해야 하는 또 다른 이유다.

---

## filesort 발생 시 내부에서 일어나는 일

정렬 대상 row가 정해지면, MySQL은 두 가지 알고리즘 중 하나를 사용한다:

### Two-pass (original) 알고리즘

```
1) 조건에 맞는 row의 (sort key + row pointer)를 sort buffer에 수집
2) sort buffer에서 정렬
3) 정렬된 순서로 row pointer를 따라 테이블을 다시 읽어서 나머지 컬럼 가져옴
```

테이블을 **두 번** 읽는다. sort buffer가 작아도 되지만, 정렬 후 테이블 재접근이 random I/O를 발생시킨다.

### Single-pass (modified) 알고리즘

```
1) 조건에 맞는 row의 (sort key + 필요한 컬럼 전부)를 sort buffer에 수집
2) sort buffer에서 정렬
3) 바로 결과 반환 (테이블 재접근 없음)
```

테이블을 **한 번**만 읽는다. 대신 sort buffer에 더 많은 데이터를 담아야 해서, row가 크면 버퍼가 빨리 찬다. `max_length_for_sort_data` 시스템 변수에 따라 MySQL이 자동으로 선택한다.

어느 쪽이든 **정렬 자체를 안 하는 것보다 빠를 수 없다**. 인덱스 설계가 우선이다.

---

## 정리

| 상황 | 해법 |
|------|------|
| `WHERE equality = ? ORDER BY col` | `(equality, col)` 복합 인덱스 |
| 여러 컬럼 정렬 | 인덱스 컬럼 순서와 ORDER BY 순서를 정확히 일치 |
| ASC/DESC 혼합 정렬 | MySQL 8.0+ DESC index 활용 |
| range 조건 + ORDER BY | equality 컬럼을 앞에, range 컬럼은 ORDER BY 뒤에 배치 |
| 이미 filesort가 불가피할 때 | LIMIT으로 정렬 대상 축소, sort_buffer_size 조정 |

`Using filesort`를 보면 당장 인덱스부터 추가하고 싶어진다. 하지만 먼저 할 일은 EXPLAIN으로 **왜 인덱스를 타지 못하는지** 확인하는 것이다. 대부분은 인덱스가 없어서가 아니라, 있는 인덱스의 컬럼 순서가 쿼리 패턴과 맞지 않아서 발생한다.

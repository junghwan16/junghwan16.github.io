---
layout: post
title: "MySQL 파티셔닝 완벽 가이드"
date: 2026-01-23 20:00:00 +0900
categories: [database, mysql]
---

회사에서 파티셔닝을 자주 사용하는데, 제 이해도가 따라가지 못한다는 걸 느꼈습니다. 특히 인덱스가 어떻게 동작하는지, FK를 지원하지 않는다는 점도 몰랐습니다. 이번 기회에 정리해봅니다.

## 파티셔닝이란?

> 거대한 데이터를 관리하기 쉽도록 작은 덩어리로 쪼개어 물리적으로 나누어 저장하는 기술

사용자에게는 하나의 논리적 테이블로 보이지만, 내부적으로는 여러 파일로 나누어 관리됩니다.

여기서 말하는 것은 **수평 파티셔닝(Horizontal Partitioning)**입니다. 행(row) 단위로 나눕니다.

```
전체 테이블
┌─────────────────────────┐
│ 1~100번 고객    → 파티션 A │
│ 101~200번 고객  → 파티션 B │
│ 201~300번 고객  → 파티션 C │
└─────────────────────────┘
```

## 왜 파티셔닝을 하는가?

| 장점 | 설명 |
|------|------|
| **쿼리 성능 향상** | WHERE 조건에 맞는 파티션만 스캔 (Partition Pruning) |
| **데이터 관리 용이** | 오래된 파티션을 통째로 삭제 가능 (DELETE보다 훨씬 빠름) |
| **저장 용량 분산** | 대용량 데이터를 여러 디스크에 분산 저장 |

## 핵심 제약사항: PK/Unique Key 규칙

파티션 키는 **반드시** 테이블의 PK나 Unique Key에 포함되어야 합니다.

### 왜 이런 제약이 있을까?

"모든 파티션을 뒤지지 않고도 유일성을 보장하기 위해서"입니다.

예를 들어 `id`가 PK인 테이블을 `created_at` 기준으로 파티셔닝했다고 가정합니다.

```
id=10 삽입 시도
  ↓
이 id가 유일한지 확인해야 함
  ↓
created_at이 파티션 키이므로 id=10이 어느 파티션에 있는지 알 수 없음
  ↓
모든 파티션을 다 뒤져야 함 → 파티셔닝 의미 없음
```

이런 비효율을 막기 위해 MySQL은 "PK/Unique Key 조회 시 단 하나의 파티션만 확인할 수 있도록" 강제합니다.

## 파티셔닝 종류

### RANGE 파티셔닝

연속적인 범위(날짜, 숫자)를 기준으로 분할합니다. **가장 흔하게 사용**됩니다.

```sql
CREATE TABLE sales (
    order_date DATE NOT NULL,
    product_id INT NOT NULL,
    quantity INT,
    PRIMARY KEY(order_date, product_id)
)
PARTITION BY RANGE (YEAR(order_date)) (
    PARTITION p2020 VALUES LESS THAN (2021),
    PARTITION p2021 VALUES LESS THAN (2022),
    PARTITION p2022 VALUES LESS THAN (2023),
    PARTITION p_max VALUES LESS THAN MAXVALUE
);
```

**적합한 경우**: 날짜별 로그, 월별 매출 데이터

### LIST 파티셔닝

미리 정해진 값 목록에 따라 분할합니다.

```sql
CREATE TABLE customers (
    id INT NOT NULL,
    name VARCHAR(255),
    country_code VARCHAR(2) NOT NULL,
    PRIMARY KEY(id, country_code)
)
PARTITION BY LIST COLUMNS(country_code) (
    PARTITION p_kr VALUES IN ('KR'),
    PARTITION p_us VALUES IN ('US'),
    PARTITION p_jp VALUES IN ('JP'),
    PARTITION p_others VALUES IN ('CN', 'TW')
);
```

**적합한 경우**: 국가 코드, 카테고리 ID처럼 명확히 구분되는 값

### HASH 파티셔닝

해시 값을 계산하여 균등하게 분배합니다.

```sql
CREATE TABLE users (
    id INT NOT NULL,
    email VARCHAR(255) NOT NULL,
    PRIMARY KEY (id)
)
PARTITION BY HASH(id)
PARTITIONS 4;
```

**적합한 경우**: 특정 그룹핑이 어려운 키 (사용자 ID 등)

### KEY 파티셔닝

HASH와 유사하지만 MySQL 내부 해시 함수를 사용합니다. 정수형이 아닌 컬럼도 파티션 키로 사용 가능합니다.

```sql
CREATE TABLE sessions (
    session_id VARCHAR(128) NOT NULL,
    user_id INT,
    created_at DATETIME,
    PRIMARY KEY (session_id)
)
PARTITION BY KEY()
PARTITIONS 8;
```

## 파티션 프루닝 (Partition Pruning)

파티셔닝의 **핵심 성능 포인트**입니다.

옵티마이저가 WHERE 절을 보고 불필요한 파티션을 제외하고, 필요한 파티션만 스캔합니다.

### 프루닝이 동작하는 경우

```sql
EXPLAIN SELECT * FROM sales WHERE order_date = '2021-06-01';
```

```
partitions: p2021  ← 이 파티션만 스캔
```

수십억 건의 데이터가 있어도 1년치 파티션만 스캔하므로 매우 빠릅니다.

### 프루닝이 동작하지 않는 경우

```sql
EXPLAIN SELECT * FROM sales WHERE product_id = 123;
```

```
partitions: p2020,p2021,p2022,p_max  ← 모든 파티션 스캔
```

WHERE 절에 파티션 키가 없으면 **모든 파티션을 스캔**합니다. 파티셔닝의 이점이 사라집니다.

> **실무 Tip**: 파티셔닝된 테이블을 쿼리할 때 WHERE 절에 파티션 키 조건을 포함시키는 것을 습관화하세요.

## FK(Foreign Key) 제약 미지원

MySQL InnoDB는 **파티셔닝된 테이블에 FK를 지원하지 않습니다**.

### 왜 지원하지 않을까?

FK 제약은 부모-자식 테이블 간 데이터 무결성을 보장합니다. 파티셔닝된 테이블 간 FK를 허용하면, 한 파티션 데이터 변경 시 다른 테이블의 여러 파티션에 걸쳐 무결성 검사가 필요합니다. 구현이 복잡하고 성능 저하가 심해서 지원하지 않습니다.

### 대안

| 방법 | 설명 |
|------|------|
| **애플리케이션 레벨 검증** | 코드에서 직접 데이터 존재 여부 확인 |
| **역정규화** | 필요한 정보를 중복 저장하여 JOIN 필요성 감소 |
| **설계 재검토** | FK가 꼭 필요하다면 파티셔닝이 최선인지 재고 |

```python
# 애플리케이션 레벨 검증 예시
def delete_user(user_id: int):
    # User 삭제 전 관련 Order 확인
    if has_orders(user_id):
        raise Error("관련 주문이 존재합니다")

    delete_user_from_db(user_id)
```

## 파티셔닝 체크리스트

### 도입 전

- [ ] 데이터가 수천만~수억 건 이상인가?
- [ ] 앞으로 빠르게 증가할 것인가?
- [ ] 인덱스만으로 해결이 안 되는가?

### 설계 시

- [ ] 가장 자주 사용되는 WHERE 조건 컬럼을 파티션 키로 선택했는가?
- [ ] 파티션 키가 PK/Unique Key에 포함되어 있는가?
- [ ] FK 제약이 필요한 테이블은 아닌가?

### 운영 시

- [ ] 쿼리에 파티션 키 조건이 포함되어 있는가?
- [ ] EXPLAIN으로 파티션 프루닝이 동작하는지 확인했는가?
- [ ] 오래된 파티션 삭제 정책이 수립되어 있는가?

## 정리

| 파티셔닝 유형 | 사용 시점 |
|-------------|----------|
| RANGE | 날짜/시간 기반 데이터 (가장 흔함) |
| LIST | 명확히 구분되는 카테고리 값 |
| HASH | 균등 분산이 필요한 경우 |
| KEY | 비정수형 키, 간단한 설정 |

파티셔닝은 대용량 데이터 관리에 강력한 도구지만, 제약사항을 이해하고 적절한 상황에서 사용해야 합니다. 특히 **파티션 키 선택**과 **프루닝 동작 여부**가 성능의 핵심입니다.

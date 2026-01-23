---
layout: post
title: "테이블이 너무 커졌을 때, 파티셔닝을 고려해야 할까"
date: 2026-01-23 20:00:00 +0900
categories: [database, mysql]
---

회사에서 파티셔닝을 자주 사용하는데, 제 이해도가 따라가지 못한다는 걸 느꼈습니다. 특히 인덱스가 어떻게 동작하는지, FK를 지원하지 않는다는 점도 몰랐습니다. 이번 기회에 정리해봅니다.

## 먼저 생각해볼 것

파티셔닝을 도입하기 전에 스스로 물어보세요:

> - 현재 테이블에 데이터가 몇 건인가?
> - 인덱스만으로 해결이 안 되는가?
> - 앞으로 데이터가 얼마나 빠르게 증가할 것인가?
> - 오래된 데이터를 주기적으로 삭제해야 하는가?

**수천만 건 이하**라면 인덱스 최적화가 먼저입니다. 파티셔닝은 복잡성을 추가하는 만큼, 정말 필요할 때만 도입하세요.

## 파티셔닝이란?

> 거대한 테이블을 작은 덩어리로 쪼개어 물리적으로 나누어 저장하는 기술

사용자에게는 하나의 논리적 테이블로 보이지만, 내부적으로는 여러 파일로 나누어 관리됩니다.

```
전체 테이블
┌─────────────────────────┐
│ 2023년 데이터 → 파티션 A │
│ 2024년 데이터 → 파티션 B │
│ 2025년 데이터 → 파티션 C │
└─────────────────────────┘
```

## 파티셔닝이 도움이 되는 경우

| 장점 | 설명 |
|------|------|
| **쿼리 성능 향상** | WHERE 조건에 맞는 파티션만 스캔 |
| **데이터 관리 용이** | 오래된 파티션을 통째로 삭제 (DELETE보다 훨씬 빠름) |
| **저장 용량 분산** | 여러 디스크에 분산 저장 가능 |

### 자가 체크

> - 당신의 테이블에서 가장 자주 사용하는 WHERE 조건은 무엇인가?
> - 오래된 데이터를 주기적으로 삭제해야 하는가?
> - 인덱스를 추가해봤는데도 느린가?

## 핵심 제약: PK/Unique Key 규칙

**파티션 키는 반드시 PK나 Unique Key에 포함되어야 합니다.**

이유: "모든 파티션을 뒤지지 않고도 유일성을 보장하기 위해서"

예를 들어 `id`가 PK인 테이블을 `created_at` 기준으로 파티셔닝했다고 가정합니다:

```
id=10 삽입 시도
  ↓
이 id가 유일한지 확인해야 함
  ↓
created_at이 파티션 키이므로 id=10이 어느 파티션에 있는지 알 수 없음
  ↓
모든 파티션을 다 뒤져야 함 → 파티셔닝 의미 없음
```

### 자가 체크

> - 당신의 테이블 PK는 무엇인가?
> - 파티션 키로 사용하려는 컬럼이 PK에 포함되어 있는가?

## 파티셔닝 종류

### RANGE 파티셔닝 (가장 흔함)

날짜/숫자 범위로 분할:

```sql
CREATE TABLE orders (
    id INT NOT NULL,
    order_date DATE NOT NULL,
    amount DECIMAL(10,2),
    PRIMARY KEY (id, order_date)  -- 파티션 키 포함!
)
PARTITION BY RANGE (YEAR(order_date)) (
    PARTITION p2023 VALUES LESS THAN (2024),
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026),
    PARTITION p_future VALUES LESS THAN MAXVALUE
);
```

**적합한 경우**: 날짜별 로그, 월별 매출 데이터

### LIST 파티셔닝

미리 정해진 값 목록으로 분할:

```sql
CREATE TABLE users (
    id INT NOT NULL,
    country_code VARCHAR(2) NOT NULL,
    PRIMARY KEY (id, country_code)
)
PARTITION BY LIST COLUMNS(country_code) (
    PARTITION p_kr VALUES IN ('KR'),
    PARTITION p_us VALUES IN ('US'),
    PARTITION p_jp VALUES IN ('JP')
);
```

**적합한 경우**: 국가 코드, 카테고리 ID

### HASH 파티셔닝

균등하게 분산:

```sql
CREATE TABLE sessions (
    id INT NOT NULL PRIMARY KEY
)
PARTITION BY HASH(id)
PARTITIONS 4;
```

**적합한 경우**: 특정 그룹핑이 어려운 경우

### 자가 체크

> - 당신의 데이터는 어떤 기준으로 나눌 수 있는가?
> - 시간 기반인가? 카테고리 기반인가? 아니면 균등 분산이 필요한가?

## 파티션 프루닝 (Partition Pruning)

**파티셔닝의 핵심 성능 포인트**입니다.

옵티마이저가 WHERE 절을 보고 불필요한 파티션을 제외합니다.

### 프루닝이 동작하는 경우

```sql
EXPLAIN SELECT * FROM orders WHERE order_date = '2024-06-01';
```

```
partitions: p2024  ← 이 파티션만 스캔
```

### 프루닝이 동작하지 않는 경우

```sql
EXPLAIN SELECT * FROM orders WHERE amount > 1000;
```

```
partitions: p2023,p2024,p2025,p_future  ← 모든 파티션 스캔
```

WHERE 절에 파티션 키가 없으면 **모든 파티션을 스캔**합니다.

### 자가 체크

> - 당신의 쿼리에 파티션 키 조건이 포함되어 있는가?
> - EXPLAIN으로 어떤 파티션이 스캔되는지 확인해봤는가?

## FK(Foreign Key) 미지원

MySQL InnoDB는 **파티셔닝된 테이블에 FK를 지원하지 않습니다.**

### 대안

| 방법 | 설명 |
|------|------|
| **애플리케이션 레벨 검증** | 코드에서 직접 데이터 존재 여부 확인 |
| **역정규화** | 필요한 정보를 중복 저장하여 JOIN 감소 |
| **설계 재검토** | FK가 꼭 필요하다면 파티셔닝이 최선인지 재고 |

```python
# 애플리케이션 레벨 검증 예시
def delete_user(user_id: int):
    if has_orders(user_id):
        raise Error("관련 주문이 존재합니다")
    delete_user_from_db(user_id)
```

### 자가 체크

> - 이 테이블에 FK 제약이 필요한가?
> - FK 없이 데이터 무결성을 어떻게 보장할 것인가?

## 도입 전 체크리스트

- [ ] 데이터가 수천만~수억 건 이상인가?
- [ ] 앞으로 빠르게 증가할 것인가?
- [ ] 인덱스만으로 해결이 안 되는가?
- [ ] 가장 자주 사용되는 WHERE 컬럼을 파티션 키로 선택했는가?
- [ ] 파티션 키가 PK/Unique Key에 포함되어 있는가?
- [ ] FK 제약이 필요한 테이블은 아닌가?

## 운영 체크리스트

- [ ] 쿼리에 파티션 키 조건이 포함되어 있는가?
- [ ] EXPLAIN으로 파티션 프루닝이 동작하는지 확인했는가?
- [ ] 오래된 파티션 삭제 정책이 수립되어 있는가?

## 자주 하는 실수

| 실수 | 결과 |
|------|------|
| 파티션 키 없이 쿼리 | 모든 파티션 풀 스캔 |
| PK에 파티션 키 미포함 | 테이블 생성 자체가 안 됨 |
| FK가 필요한 테이블에 적용 | FK 제약 사용 불가 |
| 너무 많은 파티션 | 관리 복잡성 증가 |

파티셔닝은 대용량 데이터 관리에 강력한 도구지만, **파티션 키 선택**과 **프루닝 동작 여부**가 성능의 핵심입니다.

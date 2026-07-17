---
title: "MySQL filesort가 보이면 먼저 볼 것"
url: "/backend/mysql/2026/04/08/mysql-filesort/"
date: 2026-04-08 18:00:00 +0900
categories: [backend, mysql]
---

`EXPLAIN`의 Extra에 `Using filesort`가 보이면 MySQL이 인덱스 순서만으로 `ORDER BY`를 처리하지 못했다는 뜻이다. 이름과 달리 항상 디스크 파일을 쓴다는 의미는 아니다. 메모리 sort buffer에서 끝날 수도 있다.

그래서 filesort가 보인다고 무조건 없앨 필요는 없다. 문제가 되는 건 정렬 대상 row가 많을 때다. 10만 건을 정렬해서 20건을 반환하는 것과, 이미 정렬된 인덱스에서 20건만 읽는 것은 비용이 다르다. `Using filesort`라는 문구보다 **정렬 대상 row 수, LIMIT, sort buffer, 쿼리 빈도**를 먼저 본다.

## 왜 발생하나

예를 들어 이런 쿼리가 있다.

```sql
SELECT *
FROM orders
WHERE status = 'active'
ORDER BY created_at DESC
LIMIT 20;
```

인덱스가 `status`에만 있으면 MySQL은 active row를 찾은 뒤, 그 row들을 `created_at`으로 다시 정렬해야 한다.

```sql
INDEX idx_status (status)
```

해결하려면 equality 조건과 정렬 컬럼을 같은 인덱스에 둔다.

```sql
CREATE INDEX idx_status_created
ON orders (status, created_at);
```

`status = 'active'`인 구간 안에서 `created_at` 순서가 이미 잡혀 있으므로, MySQL은 뒤에서부터 읽으며 20건을 찾고 멈출 수 있다.

기본 규칙은 `WHERE equality 컬럼 → ORDER BY 컬럼` 순서다. 여러 equality 조건이 있다면 그 컬럼들을 앞에 두고, 마지막에 정렬 컬럼을 둔다. 쿼리 패턴이 바뀌면 인덱스도 다시 봐야 한다.

## filesort를 만드는 흔한 패턴

| 패턴 | 이유 |
|---|---|
| `ORDER BY`가 인덱스 컬럼 순서와 다름 | B-Tree 순서를 그대로 쓸 수 없음 |
| 왼쪽 prefix를 건너뜀 | `(a, b)` 인덱스에서 `ORDER BY b`만 사용 불가 |
| range 조건 뒤 컬럼으로 정렬 | range 이후 컬럼의 전역 정렬 보장이 깨짐 |
| ASC/DESC 방향이 인덱스와 다름 | 방향 혼합은 인덱스 정의와 맞아야 함 |
| select row가 너무 큼 | sort buffer 압박 증가 |

range 조건은 특히 자주 헷갈린다.

```sql
WHERE created_at >= '2026-01-01'
ORDER BY status
```

`created_at` 범위 안에서 `status`가 원하는 순서로 정렬되어 있다고 보장하기 어렵다. equality 조건이 정렬을 돕고, range 조건은 그 이후 인덱스 활용을 제한한다.

## 그래도 없앨지 판단하기

작은 결과 집합에서는 filesort가 문제가 아닐 수 있다. 인덱스를 추가하면 쓰기 비용과 저장 공간도 늘어나므로, 없애기 전에 먼저 확인한다.

- `EXPLAIN`의 `rows`가 큰가?
- `WHERE`가 충분히 row를 줄이는가?
- `ORDER BY`와 인덱스 순서가 맞는가?
- `LIMIT`이 있는가?
- covering index로 bookmark lookup을 줄일 수 있는가?

느린 쿼리가 실제 트래픽에서 의미 있는 비중인지 확인한 뒤 인덱스를 추가한다.

## 남는 기준

`Using filesort`를 보면 "정렬을 없애야 한다"보다 "인덱스가 WHERE와 ORDER BY를 동시에 만족하는가"를 먼저 묻는다. 가장 흔한 해법은 `(필터 equality 컬럼, 정렬 컬럼)` 복합 인덱스다.

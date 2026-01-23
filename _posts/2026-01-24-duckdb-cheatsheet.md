---
layout: post
title: "DuckDB 치트시트"
date: 2026-01-24 14:00:00 +0900
categories: [data, sql]
---

DuckDB CLI 및 SQL 문법 치트시트입니다.

## CLI 기본

```bash
duckdb -c "SELECT * FROM 'file.parquet'"
duckdb mydb.duckdb
```

## 파일 읽기

### Parquet

```sql
SELECT * FROM 'data.parquet';
SELECT * FROM 'data/*.parquet';          -- 와일드카드
SELECT * FROM read_parquet('data.parquet');
```

### CSV

```sql
SELECT * FROM 'data.csv';
SELECT * FROM read_csv('data.csv', header=true, delim=',');
SELECT * FROM read_csv_auto('data.csv'); -- 자동 감지
```

### JSON

```sql
SELECT * FROM 'data.json';
SELECT * FROM read_json_auto('data.json');
```

## 파일 쓰기

```sql
-- Parquet로 저장
COPY (SELECT * FROM tbl) TO 'out.parquet' (FORMAT PARQUET);

-- CSV로 저장
COPY (SELECT * FROM tbl) TO 'out.csv' (HEADER, DELIMITER ',');
```

## 스키마 확인

```sql
DESCRIBE SELECT * FROM 'file.parquet';
DESCRIBE tbl;
SHOW TABLES;
```

## 유용한 함수

### 집계

```sql
COUNT(*), SUM(col), AVG(col), MIN(col), MAX(col)
COUNT(DISTINCT col)
```

### 문자열

```sql
CONCAT(a, b), LENGTH(str), LOWER(str), UPPER(str)
SUBSTR(str, start, len), REPLACE(str, from, to)
SPLIT_PART(str, delim, n), REGEXP_MATCHES(str, pattern)
```

### 날짜/시간

```sql
NOW(), CURRENT_DATE, CURRENT_TIMESTAMP
DATE_TRUNC('day', ts), DATE_PART('year', ts)
EXTRACT(MONTH FROM ts)
ts + INTERVAL '1 day'
```

### 타입 변환

```sql
CAST(col AS INTEGER), col::VARCHAR
TRY_CAST(col AS INTEGER)  -- 실패시 NULL
```

### 조건

```sql
COALESCE(a, b), NULLIF(a, b)
CASE WHEN cond THEN x ELSE y END
```

## 윈도우 함수

```sql
ROW_NUMBER() OVER (PARTITION BY col ORDER BY col2)
RANK(), DENSE_RANK()
LAG(col, 1), LEAD(col, 1)
SUM(col) OVER (PARTITION BY grp)
```

## 샘플링

```sql
SELECT * FROM tbl USING SAMPLE 10;        -- 10행
SELECT * FROM tbl USING SAMPLE 10%;       -- 10%
SELECT * FROM tbl ORDER BY RANDOM() LIMIT 10;
```

## CTE (WITH 절)

```sql
WITH cte AS (
  SELECT * FROM tbl WHERE x > 10
)
SELECT * FROM cte;
```

## 테이블 생성

```sql
CREATE TABLE tbl AS SELECT * FROM 'file.parquet';
CREATE TEMP TABLE tmp AS SELECT 1;
```

## 출력 포맷 (CLI)

```bash
duckdb -csv -c "SELECT ..."    # CSV 출력
duckdb -json -c "SELECT ..."   # JSON 출력
duckdb -line -c "SELECT ..."   # 세로 출력
duckdb -box -c "SELECT ..."    # 박스 (기본값)
```

## 설정

```sql
SET threads TO 4;
SET memory_limit = '4GB';
.maxrows 100                   -- CLI에서 출력 행 제한
```

## 자주 쓰는 패턴

### 그룹별 Top N

```sql
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY grp ORDER BY val DESC) as rn
  FROM tbl
) WHERE rn <= 3;
```

### 피벗

```sql
PIVOT tbl ON category USING SUM(value);
```

### 언피벗

```sql
UNPIVOT tbl ON (col1, col2) INTO NAME 'category' VALUE 'value';
```

### 중복 제거

```sql
SELECT DISTINCT ON (col) * FROM tbl ORDER BY col, ts DESC;
```

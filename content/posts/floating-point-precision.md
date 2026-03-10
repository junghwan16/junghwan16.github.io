---
title: "부동소수점 연산 순서가 결과를 바꾸는 이유"
url: "/cs/floating-point/2026/03/10/floating-point-precision/"
date: 2026-03-10 14:00:00 +0900
categories: [cs, floating-point]
math: true
---

IEEE 754 부동소수점은 가수부(mantissa)의 유한한 비트 수 때문에 연산 순서에 따라 결과가 달라진다. 왜 비슷한 크기의 수끼리 먼저 더해야 하는지, 곱셈·나눗셈에서는 어떤 문제가 생기는지, 그리고 실무에서 돈 계산을 어떻게 처리하는지 정리했다.

## IEEE 754 구조 복습

64비트 double 기준:

```
┌──────┬───────────┬──────────────────────────────────────────────────┐
│ 부호 │  지수부   │                   가수부                         │
│ 1bit │  11bit    │                   52bit                          │
└──────┴───────────┴──────────────────────────────────────────────────┘
```

실제 값은 다음과 같이 결정된다.

$$(-1)^{s} \times 1.m \times 2^{e - 1023}$$

가수부 52비트는 약 15~17자리의 십진수 정밀도를 제공한다. 이 유한한 비트 수가 모든 문제의 출발점이다.

## 덧셈에서 연산 순서가 중요한 이유

### 스케일이 다른 수의 덧셈

두 수를 더하려면 지수를 맞춰야 한다. 작은 수의 가수부를 오른쪽으로 시프트하는데, 이때 52비트 밖으로 밀려나는 비트는 **버려진다**.

```
  1.0 × 2^53  = 9007199254740992.0
+ 1.0 × 2^0   = 1.0

지수를 맞추면:
  1.0000000000000000000000000000000000000000000000000000  × 2^53
+ 0.0000000000000000000000000000000000000000000000000000(1) × 2^53
                                                          ↑
                                                  52비트 밖 → 소멸
```

결과: $9007199254740992.0 + 1.0 = 9007199254740992.0$. 1이 완전히 사라진다.

### 누적 합산의 차이

10만 개의 `0.1`을 합산하는 상황을 보자.

**나쁜 순서: 큰 수에 작은 수를 계속 더하기**

```python
total = 0.0
for _ in range(100_000):
    total += 0.1
print(f"{total:.20f}")
# 10000.00000000018189894
```

누적값이 커질수록 `0.1`의 하위 비트가 점점 더 많이 잘린다.

**좋은 순서: 비슷한 크기끼리 먼저 더하기 (pairwise summation)**

```python
import math

values = [0.1] * 100_000

def pairwise_sum(arr):
    if len(arr) <= 256:
        return math.fsum(arr[:1]) if len(arr) == 1 else sum(arr)
    mid = len(arr) // 2
    return pairwise_sum(arr[:mid]) + pairwise_sum(arr[mid:])

print(f"{pairwise_sum(values):.20f}")
# 10000.00000000000000000 에 훨씬 근접
```

비슷한 크기의 수끼리 더하면 지수 차이가 적어서 시프트로 손실되는 비트가 최소화된다.

### Kahan Summation

오차를 보상하는 알고리즘도 있다.

```python
def kahan_sum(values):
    total = 0.0
    compensation = 0.0       # 손실된 하위 비트 누적
    for x in values:
        y = x - compensation  # 이전 오차 보상
        t = total + y
        compensation = (t - total) - y  # 새로 발생한 오차 포착
        total = t
    return total

values = [0.1] * 100_000
print(f"{kahan_sum(values):.20f}")
# 10000.00000000000182077
```

Python의 `math.fsum()`은 내부적으로 이보다 더 정밀한 알고리즘을 사용한다.

## 뺄셈: 재앙적 소거

크기가 비슷한 두 수를 빼면 유효 숫자가 급격히 줄어든다. 이를 **catastrophic cancellation**(재앙적 소거)이라 한다.

```python
a = 1.0000000000000002  # 1 + 2ε
b = 1.0000000000000000  # 1

c = a - b
# 기대값: 2.220446049250313e-16
# 실제값: 2.220446049250313e-16 (이 경우 정확하지만)
```

문제는 이 차이를 다시 다른 연산에 사용할 때 발생한다. 유효 숫자가 1~2개만 남은 상태에서 추가 연산을 하면 상대 오차가 폭발한다.

이차방정식의 근의 공식이 대표적인 예시다.

$$x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$$

$b^2 \gg 4ac$이면 $\sqrt{b^2 - 4ac} \approx |b|$가 되어, $-b + \sqrt{b^2-4ac}$에서 재앙적 소거가 발생한다.

```python
import math

a, b, c = 1.0, 1e8, 1.0

# 직접 계산 (재앙적 소거 발생)
discriminant = math.sqrt(b*b - 4*a*c)
x1 = (-b + discriminant) / (2*a)
x2 = (-b - discriminant) / (2*a)
print(f"x1 = {x1:.15e}")   # -7.450580596923828e-09 (오차 큼)
print(f"x2 = {x2:.15e}")   # -1.000000000000000e+08

# 안정적 계산 (비에타 공식 활용)
x2_stable = (-b - discriminant) / (2*a)
x1_stable = c / (a * x2_stable)  # x1 * x2 = c/a 이용
print(f"x1 = {x1_stable:.15e}")  # -1.000000000000000e-08 (정확)
```

## 곱셈과 나눗셈의 정밀도 문제

### 곱셈: 가수부끼리의 곱

두 수를 곱하면 가수부끼리 곱해진다.

$$1.m_1 \times 1.m_2 = 1.m_{result}$$

52비트 × 52비트의 결과는 최대 104비트가 되지만, 저장할 수 있는 건 52비트뿐이다. 나머지는 반올림(round-to-nearest-even)으로 잘린다.

```python
a = 1.0000000000000002  # 1 + 2ε
b = 1.0000000000000003  # 1 + 3ε

# 정확한 값: 1 + 5ε + 6ε²
# 6ε² ≈ 2.96e-32 → double로 표현 불가
print(f"{a * b:.20e}")
# 1.00000000000000044409e+00
```

한 번의 곱셈에서 발생하는 오차는 작지만, **연쇄 곱셈**에서 오차가 누적된다.

### 연쇄 곱셈의 순서

덧셈처럼 극적이지는 않지만, 곱셈에서도 순서가 영향을 준다. 핵심은 **중간 결과의 오버플로우/언더플로우 방지**다.

```python
import math

# 큰 수끼리 먼저 곱하면 오버플로우
a = 1e200
b = 1e200
c = 1e-200

print(a * b * c)    # inf × 1e-200 = inf  (오버플로우!)
print(a * c * b)    # 1.0 × 1e200 = 1e200 (정상)
```

나눗셈에서도 마찬가지다.

```python
a = 1e-300
b = 1e-300
c = 1e300

print(a / b * c)    # 1.0 × 1e300 = 1e300 (정상)
print(a * c / b)    # 1.0 / 1e-300 = 1e300 (정상)
print(a / (b / c))  # 1e-300 / 1e-600 = inf (오버플로우!)
```

**곱셈·나눗셈 가이드라인:**

| 상황 | 전략 |
|---|---|
| 큰 수 × 큰 수 | 사이에 작은 수(또는 나눗셈)를 끼워 스케일 유지 |
| 작은 수 × 작은 수 | 사이에 큰 수를 끼워 언더플로우 방지 |
| 비율 계산 ($a/b \times c/d$) | $(a \times c) / (b \times d)$ 대신 $(a/b) \times (c/d)$로 분리 |

### 나눗셈 반복의 오차 누적

나눗셈을 반복하면 매 단계마다 반올림 오차가 곱해진다.

```python
x = 1.0
for _ in range(10):
    x /= 3.0
for _ in range(10):
    x *= 3.0

print(f"{x:.20f}")
# 0.99999999999999977796  (1.0이 아님)
```

10번 나누고 10번 곱해도 원래 값으로 돌아오지 않는다. 이건 $1/3$이 이진 부동소수점으로 정확히 표현되지 않기 때문이다.

## 실무: 기업은 돈 계산을 어떻게 하는가

부동소수점으로 금액을 계산하면 안 된다. `0.1 + 0.2 ≠ 0.3`은 유명한 예시지만, 실제 금융 시스템에서는 이보다 훨씬 심각한 문제가 발생한다.

### 1. 정수 기반 처리 (가장 보편적)

금액을 **최소 화폐 단위**의 정수로 저장한다.

```java
// ❌ 절대 하지 말 것
double price = 19.99;
double total = price * 3;  // 59.970000000000006

// ✅ 센트 단위 정수 처리
long priceInCents = 1999;
long total = priceInCents * 3;  // 5997 → $59.97 정확
```

대부분의 결제 시스템(Stripe, PayPal)이 이 방식을 사용한다. Stripe API는 금액을 센트 단위 정수로 받는다.

```json
{
  "amount": 1999,
  "currency": "usd"
}
```

원화처럼 소수점이 없는 통화는 원 단위 정수를 그대로 사용하면 된다.

### 2. 고정소수점 / Decimal 타입

언어에서 제공하는 임의 정밀도 십진 타입을 사용한다.

```python
from decimal import Decimal, ROUND_HALF_UP

price = Decimal("19.99")       # 문자열로 초기화해야 정확
tax_rate = Decimal("0.08")
tax = (price * tax_rate).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
total = price + tax

print(total)  # 21.59 (정확)
```

```java
// Java의 BigDecimal
BigDecimal price = new BigDecimal("19.99");
BigDecimal taxRate = new BigDecimal("0.08");
BigDecimal tax = price.multiply(taxRate)
    .setScale(2, RoundingMode.HALF_UP);
BigDecimal total = price.add(tax);
// 21.59 (정확)
```

주의: `new BigDecimal(0.1)`처럼 `double`에서 변환하면 이미 오염된 값이 들어간다. 반드시 **문자열로 초기화**해야 한다.

```java
new BigDecimal(0.1);      // 0.1000000000000000055511151231257827021181583404541015625
new BigDecimal("0.1");    // 0.1
```

### 3. 데이터베이스에서의 처리

```sql
-- ❌
CREATE TABLE products (
    price FLOAT
);

-- ✅
CREATE TABLE products (
    price DECIMAL(10, 2)    -- 총 10자리, 소수점 이하 2자리
);

-- 또는 정수 저장
CREATE TABLE products (
    price_cents INTEGER     -- 센트 단위
);
```

MySQL의 `DECIMAL`, PostgreSQL의 `NUMERIC`은 내부적으로 BCD(Binary-Coded Decimal)나 유사한 방식으로 십진수를 정확히 표현한다.

### 4. 반올림 규칙

금융에서는 **Banker's rounding** (round half to even)을 사용하는 경우가 많다.

| 값 | 일반 반올림 | Banker's Rounding |
|---|---|---|
| 0.5 | 1 | 0 (짝수로) |
| 1.5 | 2 | 2 (짝수로) |
| 2.5 | 3 | 2 (짝수로) |
| 3.5 | 4 | 4 (짝수로) |

0.5를 항상 올림하면 대량 거래에서 통계적 편향이 발생한다. Banker's rounding은 이 편향을 제거한다.

IEEE 754의 기본 반올림 모드가 바로 이 round-to-nearest-even이다.

### 5. 실제 기업 사례

**Stripe**: 모든 금액을 최소 화폐 단위의 정수로 처리. API에서 `float`/`double` 타입을 아예 받지 않는다.

**Amazon**: 내부적으로 금액을 정수(센트/페니)로 저장하고, 표시할 때만 변환한다. 세금 계산은 항목별로 수행한 뒤 합산한다(합산 후 세금 계산이 아님).

**은행권**: COBOL의 `PACKED-DECIMAL` 타입을 수십 년간 사용해왔다. 내부적으로 BCD 인코딩으로 십진수를 정확히 표현한다. 현대 시스템에서도 Java `BigDecimal`이나 .NET `decimal`을 사용한다.

**거래소**: 가격을 정수 틱(tick) 단위로 처리. 예를 들어 주가가 $150.25이면 `15025`로 저장한다.

## 정리

| 문제 | 원인 | 해결 |
|---|---|---|
| 큰 수 + 작은 수 = 큰 수 | 지수 정렬 시 가수부 비트 소멸 | 비슷한 스케일끼리 먼저 연산 |
| 비슷한 수의 뺄셈 → 유효 숫자 손실 | 재앙적 소거 | 수식 변환으로 뺄셈 회피 |
| 연쇄 곱셈의 오버/언더플로우 | 중간 결과의 스케일 폭발 | 큰 수와 작은 수를 교차 배치 |
| 돈 계산의 오차 | 이진수로 십진 소수를 정확히 표현 불가 | 정수 또는 Decimal 타입 사용 |

핵심은 하나다: **부동소수점의 가수부는 52비트밖에 안 된다.** 연산할 때 이 52비트 안에 유효한 정보가 최대한 보존되도록 순서를 설계해야 하고, 정확성이 필수인 금융 계산에서는 아예 부동소수점을 쓰지 않는 것이 정답이다.

## 참고 자료

- [What Every Computer Scientist Should Know About Floating-Point Arithmetic](https://docs.oracle.com/cd/E19957-01/806-3568/ncg_goldberg.html)
- [IEEE 754 - Wikipedia](https://en.wikipedia.org/wiki/IEEE_754)
- [Stripe API - Amount](https://docs.stripe.com/api/charges/create#create_charge-amount)
- [Kahan Summation Algorithm - Wikipedia](https://en.wikipedia.org/wiki/Kahan_summation_algorithm)
- [Catastrophic Cancellation - Wikipedia](https://en.wikipedia.org/wiki/Catastrophic_cancellation)

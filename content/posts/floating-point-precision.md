---
title: "부동소수점은 더하는 순서도 탄다"
url: "/cs/floating-point/2026/03/10/floating-point-precision/"
date: 2026-03-10 14:00:00 +0900
categories: [cs, floating-point]
---

같은 숫자를 더해도 순서를 바꾸면 결과가 달라질 수 있다. 부동소수점은 실수를 무한히 정확하게 저장하지 않는다. 제한된 비트 안에 근사값을 담고, 연산할 때마다 반올림한다.

핵심은 큰 수와 작은 수를 섞어 계산할 때 작은 수의 하위 비트가 사라진다는 점이다.

## 왜 `큰 수 + 1`이 그대로일까

double은 52비트 가수부를 가진다. 큰 수와 작은 수를 더하려면 지수를 맞춰야 하고, 작은 수의 가수부를 오른쪽으로 밀어야 한다. 그 과정에서 표현 범위 밖으로 밀린 비트는 버려진다.

```python
>>> 2**53
9007199254740992
>>> float(2**53) + 1
9007199254740992.0
```

`1`이 사라진 것이 아니라, 그 크기의 double이 더 이상 1 단위 간격을 표현하지 못하는 것이다.

## 합산 순서가 결과를 바꾼다

작은 값을 계속 큰 누적값에 더하면 매번 조금씩 손실된다.

```python
total = 0.0
for _ in range(100_000):
    total += 0.1

print(f"{total:.20f}")
# 10000.00000000018189894
```

비슷한 크기끼리 먼저 더하면 손실이 줄어든다. 그래서 대량 합산에서는 pairwise summation이나 `math.fsum()` 같은 보정 알고리즘을 쓴다.

```python
import math

values = [0.1] * 100_000
print(f"{math.fsum(values):.20f}")
# 10000.00000000000000000
```

부동소수점 덧셈은 수학의 실수 덧셈처럼 완전히 결합법칙을 만족하지 않는다.

## 뺄셈은 유효 숫자를 날릴 수 있다

크기가 비슷한 두 수를 빼면 앞자리 대부분이 서로 지워지고, 남은 하위 자리만 결과가 된다. 이를 catastrophic cancellation이라고 부른다.

이차방정식 근의 공식이 대표적인 예다.

```python
import math

a, b, c = 1.0, 1e8, 1.0
d = math.sqrt(b*b - 4*a*c)

x1 = (-b + d) / (2*a)
x2 = (-b - d) / (2*a)

print(x1)  # -7.450580596923828e-09
print(x2)  # -100000000.0
```

`x1`은 작은 근인데, `-b + sqrt(...)`에서 비슷한 큰 수를 빼며 정확도가 크게 줄었다. 이런 경우에는 수식을 바꿔 직접 뺄셈을 피한다.

```python
x2 = (-b - d) / (2*a)
x1 = c / (a * x2)
```

## 돈 계산에는 쓰지 않는다

`0.1 + 0.2 != 0.3`은 장난감 문제가 아니다. 결제, 정산, 세금 계산에서 double을 쓰면 반올림 규칙과 누적 오차가 계약이 되어버린다. 금액은 보통 최소 화폐 단위 정수(1999 cents)나 decimal 타입(`BigDecimal`, `Decimal`, DB `DECIMAL`)으로 처리한다.

## 남는 규칙

- 큰 수와 작은 수를 섞어 더하면 작은 수가 사라진다. 대량 합산은 `fsum` 같은 보정 알고리즘을 쓴다.
- 비슷한 큰 수의 뺄셈은 수식 변환으로 피한다.
- 돈, 포인트, 정산 금액은 float가 아니라 정수나 decimal로 다룬다.

부동소수점은 틀린 계산기가 아니라 정밀도를 제한한 표현 방식이다. 문제는 그 제한을 모른 채 정확한 십진 계산처럼 쓰는 데서 생긴다.

## 참고자료

- [What Every Computer Scientist Should Know About Floating-Point Arithmetic](https://docs.oracle.com/cd/E19957-01/806-3568/ncg_goldberg.html)
- [Python math.fsum](https://docs.python.org/3/library/math.html#math.fsum)
- [Python decimal](https://docs.python.org/3/library/decimal.html)

---
title: "2의 보수에서 -INT_MIN == INT_MIN이 되는 이유"
url: "/cs/binary/2026/03/10/twos-complement-overflow/"
date: 2026-03-10 10:00:00 +0900
categories: [cs, binary]
math: true
---

32비트 signed int에서 최솟값을 부정(negate)하면 다시 자기 자신이 된다. 2의 보수 표현의 비대칭성에서 비롯되는 이 현상을 비트 레벨부터 하드웨어 설계 이유까지 정리했다.

## 32비트 signed int의 범위

2의 보수(two's complement)에서 $n$비트 정수의 범위는 다음과 같다.

$$-2^{n-1} \leq x \leq 2^{n-1} - 1$$

32비트 기준으로 정리하면:

| 구분 | 값 | 비트 패턴 |
|---|---|---|
| 최솟값 | -2,147,483,648 ($-2^{31}$) | `10000000 00000000 00000000 00000000` |
| 최댓값 | 2,147,483,647 ($2^{31}-1$) | `01111111 11111111 11111111 11111111` |
| 0 | 0 | `00000000 00000000 00000000 00000000` |

양수는 $2^{31} - 1$개, 음수는 $2^{31}$개, 0은 1개. 음수가 양수보다 1개 더 많다.

## 반전 + 1 하면 왜 같은 값이 나오나

2의 보수에서 부호를 뒤집는 방법은 **비트 반전 후 +1**이다. `INT_MIN`에 적용해 보자.

```
원본:   10000000 00000000 00000000 00000000   (-2147483648)

① 반전: 01111111 11111111 11111111 11111111   (2147483647)

② +1:   10000000 00000000 00000000 00000000   (오버플로우 → -2147483648)
```

$2^{31} - 1$에 1을 더하면 $2^{31}$이 필요한데, 32비트 signed int로는 이 값을 표현할 수 없다. 결과적으로 비트 패턴이 다시 원래 값으로 돌아온다.

수식으로 보면:

$$-(-2^{31}) = 2^{31}$$

인데 $2^{31}$은 표현 범위 밖이므로 $\mod 2^{32}$로 감싸지면서 다시 $-2^{31}$이 된다.

## 실제 코드에서의 동작

### C/C++: 정의되지 않은 동작 (Undefined Behavior)

```c
#include <limits.h>
#include <stdio.h>

int main(void) {
    int x = INT_MIN;  // -2147483648
    int y = -x;       // undefined behavior!
    printf("%d\n", y);
    return 0;
}
```

C/C++ 표준에서 signed integer overflow는 **정의되지 않은 동작(UB)**이다. 컴파일러가 "signed int는 오버플로우하지 않는다"는 가정하에 최적화를 수행하기 때문에, `-INT_MIN`의 결과를 예측할 수 없다. 대부분의 플랫폼에서 `-2147483648`이 출력되지만, 이에 의존하면 안 된다.

대표적으로 컴파일러가 UB를 활용하는 예시:

```c
// 컴파일러는 signed overflow가 없다고 가정하므로
// 이 조건문을 항상 true로 최적화할 수 있다
if (x + 1 > x) { ... }
```

### Java: 조용한 래핑 (Silent Wrapping)

```java
int x = Integer.MIN_VALUE;  // -2147483648
int y = -x;                 // -2147483648 (명세에 의해 보장)
System.out.println(y);      // -2147483648
```

Java는 2의 보수 래핑이 언어 명세에 정의되어 있어 결과가 보장된다.

### Rust: 패닉 또는 래핑

```rust
let x: i32 = i32::MIN;
// debug 모드: panic (overflow detected)
// release 모드: 래핑되어 -2147483648
let y = -x;
```

Rust는 debug 빌드에서 overflow를 감지하고 패닉을 발생시키며, 의도적인 래핑이 필요하면 `wrapping_neg()`을 사용한다.

## C/C++에서 안전하게 처리하는 방법

### 1. 부정 전 명시적 검사

```c
#include <limits.h>
#include <stdlib.h>

int safe_negate(int x) {
    if (x == INT_MIN) {
        // 별도 처리: 에러 반환, 클램핑, 또는 long long 사용
        return INT_MAX;  // 또는 에러 처리
    }
    return -x;
}
```

### 2. unsigned로 변환 후 연산

```c
unsigned int abs_val = -(unsigned int)x;
```

unsigned 산술은 $\mod 2^{32}$로 정의되어 있으므로 UB가 발생하지 않는다.

### 3. `-fwrapv` 컴파일러 플래그

GCC/Clang에서 `-fwrapv` 옵션을 사용하면 signed overflow도 2의 보수 래핑으로 동작하도록 보장한다. 다만 컴파일러 최적화 기회를 일부 포기하게 된다.

## abs(INT_MIN)도 같은 문제

```c
#include <stdlib.h>

int val = abs(INT_MIN);  // undefined behavior!
// 대부분의 구현에서 INT_MIN을 반환
```

`abs()` 함수도 내부적으로 부정 연산을 수행하므로 동일한 문제가 발생한다. 외부 입력에 대해 `abs()`를 호출할 때는 반드시 `INT_MIN` 여부를 확인해야 한다.

## 왜 컴퓨터는 2의 보수를 사용하는가

이 모든 비대칭성에도 불구하고 2의 보수가 표준인 이유는 하드웨어 효율성 때문이다.

### 덧셈기 하나로 덧셈과 뺄셈 모두 처리

```
A - B = A + (-B) = A + (NOT B + 1)
```

뺄셈을 위한 별도의 회로가 필요 없다. XOR 게이트로 비트를 반전하고 캐리 입력을 1로 설정하면 같은 가산기(adder)로 뺄셈이 수행된다.

```
┌──────────────────────────────────────────────────┐
│              Adder / Subtractor                   │
│                                                   │
│  A ──────────────┐                                │
│                  ├──→ [  Full Adder  ] ──→ Result │
│  B ──→ [XOR] ───┘          ↑                      │
│           ↑            Carry-in                    │
│        SUB 신호 ───────────┘                       │
│                                                   │
│  SUB=0: A + B      (XOR 통과, carry-in=0)         │
│  SUB=1: A + ~B + 1 (XOR 반전, carry-in=1) = A - B │
└──────────────────────────────────────────────────┘
```

### 0의 표현이 유일

1의 보수(ones' complement)에서는 `+0`과 `-0`이 존재한다.

| 표현 방식 | +0 | -0 |
|---|---|---|
| 1의 보수 | `0000 0000` | `1111 1111` |
| 2의 보수 | `0000 0000` | (없음) |

0이 두 개이면 비교 연산에서 추가 로직이 필요하고, 표현 가능한 숫자가 하나 줄어든다.

### 부호 무관한 산술 연산

2의 보수에서는 덧셈, 뺄셈, 곱셈이 unsigned와 **동일한 회로**로 동작한다. 하드웨어가 부호를 알 필요 없이 같은 비트 연산을 수행하면 된다.

### 역사적 배경

John von Neumann이 1945년 EDVAC 보고서에서 2의 보수 이진 표현을 제안했고, 1949년 EDSAC에서 채택되었다. 이후 하드웨어 비용과 복잡도 측면에서 1의 보수와 부호-크기(sign-magnitude) 방식을 완전히 대체했다.

## 정리

| 항목 | 내용 |
|---|---|
| `INT_MIN`의 비트 패턴 | `10000000 00000000 00000000 00000000` |
| 반전 + 1 결과 | 다시 같은 비트 패턴 |
| 근본 원인 | $+2^{31}$을 32비트 signed int로 표현할 수 없음 |
| C/C++에서의 `-INT_MIN` | 정의되지 않은 동작 (UB) |
| Java에서의 `-Integer.MIN_VALUE` | 명세에 의해 래핑 보장 |
| 2의 보수를 쓰는 이유 | 가산기 하나로 덧셈/뺄셈 처리, 0이 유일, 회로 단순화 |

## 참고 자료

- [SEI CERT C Coding Standard - INT32-C](https://wiki.sei.cmu.edu/confluence/display/c/INT32-C.+Ensure+that+operations+on+signed+integers+do+not+result+in+overflow)
- [Two's complement - Wikipedia](https://en.wikipedia.org/wiki/Two's_complement)
- [Why computers represent signed integers using two's complement](https://igoro.com/archive/why-computers-represent-signed-integers-using-twos-complement/)
- [A Guide to Undefined Behavior in C and C++ - Embedded in Academia](https://blog.regehr.org/archives/226)

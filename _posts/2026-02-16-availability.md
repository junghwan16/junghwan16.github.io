---
layout: single
title: "가용성(Availability)이란 무엇인가"
date: 2026-02-16 12:00:00 +0900
categories: [backend, infrastructure]
---

컴퓨터 과학에서 가용성(Availability)이란 **시스템이 필요할 때 정상적으로 동작하고 접근 가능한 상태에 있는 정도**를 의미한다.

더 정확하게 말하면, 전체 시간 중 시스템이 정상적으로 서비스한 시간의 비율이다.

---

## 공식

$$\text{가용성} = \frac{\text{Uptime}}{\text{Uptime} + \text{Downtime}}$$

---

## 예시

1년은 약 365일 × 24시간 = **8,760시간**이다.

만약 1년에 8시간 장애가 났다면:

$$\text{가용성} = \frac{8752}{8760} \approx 99.91\%$$

---

## Nine의 개수

흔히 가용성을 "9가 몇 개인가"로 표현한다.

| 가용성 | 1년 기준 최대 다운타임 |
|---|---|
| 99% (Two 9s) | 약 3.65일 |
| 99.9% (Three 9s) | 약 8.76시간 |
| 99.99% (Four 9s) | 약 52분 |
| 99.999% (Five 9s) | 약 5분 |

퍼센트 뒤에 붙는 9의 개수가 많을수록 "거의 안 멈추는 시스템"이라는 뜻이다.

9 하나가 추가될 때마다 허용 다운타임이 **10분의 1**로 줄어든다. 99.9% → 99.99%는 고작 0.09%p 차이지만, 허용 장애 시간은 8시간에서 52분으로 줄어든다. 이 차이를 만들어내는 데 드는 엔지니어링 비용은 기하급수적으로 올라간다.

---

## MTBF와 MTTR

가용성은 두 가지 지표로 분해할 수 있다.

- **MTBF**(Mean Time Between Failures): 장애와 장애 사이의 평균 시간. 시스템이 얼마나 오래 정상 동작하는가.
- **MTTR**(Mean Time To Repair): 장애 발생 후 복구까지 걸리는 평균 시간.

$$\text{가용성} = \frac{\text{MTBF}}{\text{MTBF} + \text{MTTR}}$$

가용성을 높이는 방법은 두 가지다.

1. **MTBF를 늘린다** — 장애 자체를 줄인다. 더 안정적인 하드웨어, 더 나은 코드.
2. **MTTR을 줄인다** — 장애가 나도 빨리 복구한다. 자동 페일오버, 모니터링, 롤백 파이프라인.

실무에서는 MTTR을 줄이는 쪽이 더 현실적이다. 장애는 반드시 발생하기 때문이다.

---

## 직렬 시스템 vs 병렬 시스템

### 직렬 (Series)

```
Client → A → B → C
```

A, B, C가 모두 동작해야 서비스가 된다. 전체 가용성은 각 컴포넌트의 곱이다.

$$\text{가용성} = A \times B \times C$$

각각 99.9%라면:

$$0.999 \times 0.999 \times 0.999 = 99.7\%$$

컴포넌트가 늘어날수록 전체 가용성은 **떨어진다**. 이것이 마이크로서비스에서 가용성이 중요한 이유다. 호출 체인이 길어질수록 전체 신뢰성이 낮아진다.

### 병렬 (Parallel)

```
        ┌→ A1
Client ─┤
        └→ A2
```

둘 중 하나만 살아있으면 된다. 전체 가용성:

$$\text{가용성} = 1 - (1 - A_1)(1 - A_2)$$

각각 99.9%라면:

$$1 - (0.001 \times 0.001) = 99.9999\%$$

이것이 이중화(Redundancy)의 수학적 근거다. 99.9% 짜리 두 대를 병렬로 놓으면 99.9999%가 된다.

---

## Single Point of Failure (SPOF)

시스템에서 하나가 죽으면 전체가 멈추는 지점을 SPOF라 한다.

```
Client → LB → App → DB (Single)
                      ↑ SPOF
```

DB가 한 대뿐이면 DB 장애 = 서비스 전체 장애다. 가용성을 높이려면 SPOF를 찾아서 이중화해야 한다.

```
Client → LB → App → DB Primary
                   ↘ DB Replica (Standby)
```

흔한 SPOF 지점:

| 계층 | SPOF | 해결 |
|---|---|---|
| 네트워크 | 단일 로드밸런서 | Active-Standby LB |
| 애플리케이션 | 단일 서버 | 다중 인스턴스 + LB |
| 데이터베이스 | 단일 DB | Primary-Replica 구성 |
| 리전 | 단일 데이터센터 | Multi-AZ / Multi-Region |

---

## 참고자료

- [Availability - Wikipedia](https://en.wikipedia.org/wiki/Availability) — 가용성의 정의와 수학적 모델
- [Calculating Availability of Complex Systems](https://www.eventhelix.com/fault-handling/system-reliability-availability/) — 직렬/병렬 시스템 가용성 계산
- [Google SRE Book - Embracing Risk](https://sre.google/sre-book/embracing-risk/) — Google이 가용성 목표를 정하는 방법

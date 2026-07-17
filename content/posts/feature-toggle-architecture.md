---
title: "Grab은 A/B 테스트 설정을 왜 SDK로 옮겼을까"
url: "/backend/architecture/2026/03/15/feature-toggle-architecture/"
date: 2026-03-15 10:00:00 +0900
categories: [backend, architecture]
---

Feature toggle은 코드 배포와 기능 공개를 분리한다. 문제는 toggle 조회가 요청 처리 경로에 들어온다는 점이다. 매 요청마다 원격 저장소를 읽으면 실험 시스템이 서비스 지연의 일부가 된다.

Grab의 사례에서 핵심은 하나다. **실험 판단은 프로세스 안의 메모리에서 끝내고, 설정 동기화는 백그라운드로 밀어낸다.**

## 레거시 방식의 문제

처음에는 하드코딩이나 공유 Redis가 쉬워 보인다.

```go
if sitevar.GetFeatureFlagOrDefault("new_flow", false) {
    runNewFlow()
}
```

하지만 실험 수와 서비스 수가 늘면 문제가 드러난다.

| 방식 | 문제 |
|---|---|
| 코드 하드코딩 | 비율과 대상 변경마다 PR, 리뷰, 배포가 필요 |
| 공유 Redis 조회 | 모든 서비스의 hot path가 Redis에 의존 |
| 중앙 서버 호출 | 지연, 장애 전파, 트래픽 증가 |

feature flag는 "장애가 나도 서비스가 계속 돌아야 하는 설정"이다. 그런데 그 설정 조회가 네트워크에 걸려 있으면 장애 반경이 커진다.

## SDK 방식

Grab은 SDK 안에 평가 모델을 두고, 설정 파일은 백그라운드에서 가져오게 했다.

```text
service process
  SDK
    in-memory model  <- background poller <- config storage
    event buffer     -> batched tracking
```

애플리케이션은 SDK를 호출한다.

```go
delay := client.GetVariable(ctx, "automatedMessageDelay", facets).Int64(30)
```

이 호출은 네트워크를 타지 않는다. 이미 메모리에 올라온 설정과 요청 context를 비교해 값을 반환한다. 설정 저장소가 잠시 느리거나 실패해도 마지막으로 성공한 설정으로 계속 동작할 수 있다.

## 왜 이 구조가 나은가

| 기준 | 공유 저장소 직접 조회 | SDK + 인메모리 평가 |
|---|---|---|
| 요청 경로 | 네트워크 I/O 포함 | 메모리 연산 |
| 저장소 장애 | 서비스 요청에 바로 영향 | 기존 설정으로 degraded 동작 |
| 트래픽 증가 | 서비스 수와 요청 수만큼 증가 | 폴링 주기와 인스턴스 수에 비례 |
| 설정 변경 | 중앙 설정 수정 | 중앙 설정 수정 |
| 실험 노출 기록 | 별도 구현 필요 | SDK가 함께 처리 가능 |

중요한 trade-off도 있다. 설정 변경이 즉시 반영되지 않는다. poll interval만큼 지연된다. feature rollout에서는 이 지연이 보통 받아들일 수 있지만, 강한 실시간 제어가 필요한 kill switch라면 별도 경로가 필요할 수 있다.

## Facet을 명시적으로 넘긴다

A/B 테스트는 단순 boolean이 아니다. 도시, 사용자, 디바이스, 서비스 타입 같은 context로 조건을 평가한다.

```go
facets := sdk.NewFacets().
    Passenger(passengerID).
    City(cityID).
    Service(serviceID)

enabled := client.GetVariable(ctx, "new_matching", facets).Bool(false)
```

context를 SDK에 명시적으로 넘기면 두 가지가 가능하다.

- 같은 입력에 대해 일관된 bucket 결정을 한다.
- 어떤 사용자가 어떤 변수를 받았는지 추적 이벤트를 남긴다.

실험 시스템은 "누구에게 무엇을 보여줬는가"를 모르면 분석할 수 없다. 그래서 평가와 트래킹은 분리된 기능처럼 보여도 같은 SDK 경계에 두는 편이 자연스럽다.

## 설계 규칙

- 요청 경로에서 원격 feature store를 직접 읽지 않는다.
- 기본값을 항상 코드에 둔다.
- 설정을 못 가져오면 마지막 정상 설정으로 동작한다.
- 실험 조건은 코드가 아니라 데이터로 표현한다.
- 실험 노출 이벤트는 SDK가 자동으로 남긴다.
- 설정 반영 지연과 kill switch 요구를 별도로 정의한다.

이 글에서 중요한 건 Grab이 S3를 썼다는 사실 자체가 아니다. feature toggle을 서비스의 hot path에 넣을 때, 원격 조회를 제거하고 실패 시 기본값으로 내려앉는 구조를 만든 점이다.

## 참고자료

- [Reliable and Scalable Feature Toggles and A/B Testing SDK at Grab](https://engineering.grab.com/feature-toggles-ab-testing)
- [Martin Fowler - Feature Toggles](https://martinfowler.com/articles/feature-toggles.html)

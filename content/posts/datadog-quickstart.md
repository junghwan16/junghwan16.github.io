---
title: "Datadog Quick Start 랩 후기"
url: "/devops/datadog/2026/03/08/datadog-quickstart/"
date: 2026-03-08 21:00:00 +0900
categories: [devops, datadog]
---

Datadog을 본격적으로 쓰기 전에 공식 Quick Start 코스부터 밟아봤다. Dashboard, Logs, Software Catalog, Monitor 네 가지 핵심 도구를 랩 환경에서 직접 만져보는 코스다. 여기서 뭘 해봤고, 어떤 인상을 받았는지 정리한다.

---

## Dashboard

랩에서 제공하는 storedog 2.0 대시보드를 열면 세 그룹의 위젯이 보인다.

![대시보드 Overall Performance와 Infra](/images/datadog-quickstart/dashboard-overview.png)

![대시보드 Databases 위젯](/images/datadog-quickstart/dashboard-databases.png)

1. **Overall Performance** --- 전반적인 성능 지표
2. **Infrastructure & Network** --- 인프라 및 네트워크 상태
3. **Databases** --- 데이터베이스 메트릭

위젯을 클릭하면 어떤 메트릭으로 구성되어 있는지, 세부 수치를 바로 확인할 수 있다.

![위젯 클릭 시 메트릭 상세](/images/datadog-quickstart/widget-detail.png)

필터를 걸어서 특정 서비스만 골라볼 수도 있다.

![대시보드 필터 선택](/images/datadog-quickstart/dashboard-filter.png)

`store-discounts` 서비스를 필터링하니 높은 에러율이 바로 눈에 들어왔다. 대시보드 하나로 문제 서비스를 빠르게 특정할 수 있다는 걸 체감한 순간이었다.

![store-discounts 서비스 에러율](/images/datadog-quickstart/store-discounts-error.png)

---

## Software Catalog

`Automation > Software Catalog` 경로로 접근한다.

![Software Catalog 화면](/images/datadog-quickstart/software-catalog.png)

서비스별 퍼포먼스, 모니터링 설정, SLO, 오너십(팀 정보, 온콜 담당자, 런북, 대시보드)을 한 곳에서 볼 수 있다. 여러 도구를 왔다 갔다 할 필요 없이 서비스 컨텍스트가 한 화면에 모여 있다는 게 편했다.

---

## Monitor

Monitor는 메트릭 임계값 초과나 자산 상태 변경을 감지해 팀에 알림을 보내는 도구다.

![Monitor 목록 화면](/images/datadog-quickstart/monitor-list.png)

![Monitor 상세 - 에러율 그래프](/images/datadog-quickstart/monitor-detail.png)

Monitor 상세 페이지 오른쪽 패널에서 세 가지를 확인한다:

1. **Query details** --- 어떤 조건으로 트리거되는지
2. **Evaluation** --- 현재 평가 상태
3. **Notification Count** --- 알림 수신자 목록

### 쿼리 해석

`store-discounts` 서비스의 에러율 모니터 쿼리를 보면:

```
sum(last_10m):(
  sum:trace.flask.request.errors{env:quickstart-course,service:store-discounts}.as_count()
  / sum:trace.flask.request.hits{env:quickstart-course,service:store-discounts}.as_count()
) > 0.05
```

최근 10분간 에러 수 / 전체 요청 수가 5%를 초과하면 ALERT 상태가 된다. `last_10m`으로 시간 범위를 지정하고, `{env:...,service:...}` 형태로 태그 필터링하고, `.as_count()`로 카운트 기반 비율을 계산하는 패턴이다.

### Event Details

![Monitor Event Details](/images/datadog-quickstart/monitor-event-detail.png)

Event Details에서 Message Template과 Recipients를 확인할 수 있다. 메시지 템플릿에 변수, 대시보드/런북 링크, Slack이나 PagerDuty 같은 외부 알림 채널을 포함시킬 수 있다.

---

## 느낀 점

Dashboard에서 문제를 발견하고, Software Catalog에서 서비스 컨텍스트를 확인하고, Monitor에서 알림 조건과 이력을 추적하는 흐름이 자연스럽게 이어졌다. 메인 내비게이션, **Go to...** 퀵 내비게이션, 각 페이지 내 상관 데이터 링크 세 가지 탐색 경로가 있어서 원하는 정보에 빠르게 도달할 수 있었다.

Monitor 쿼리 문법과 태그 필터링은 따로 깊이 파봐야 할 것 같다. 다음은 Datadog Foundation 코스를 들을 예정이다.

![수료증](/images/datadog-quickstart/certificate.png)

수료증의 한글이 깨지는 건 좀 아쉬웠다.

---
layout: single
title: "OpenRTB URL 호출 주체 정리 (서버 vs 클라이언트)"
date: 2026-02-24 20:00:00 +0900
categories: [ad-tech, openrtb]
---

> OpenRTB에는 다양한 URL이 등장한다. 어떤 건 서버가 호출하고, 어떤 건 클라이언트(브라우저/SDK)가 호출한다.
> 이걸 헷갈리면 과금 누락, 중복 집계, 트래킹 실패가 발생한다.
> **이 문서는 논란 없이 확정적으로 정리한다.**

> **💡 Tip: 비유로 이해하기**
> OpenRTB에는 수많은 URL이 등장합니다. "누가 이 URL을 호출하는가?"가 핵심입니다.
>
> **택배 배송**에 비유하면:
> - **서버가 호출하는 URL** (nurl, burl, lurl): 택배 회사 본사끼리 하는 통화.
>   "물건 배송 완료했습니다" (nurl), "대금 정산합니다" (burl), "배송 취소됐습니다" (lurl)
>   → 고객(사용자)은 이 통화를 알 수 없고, 알 필요도 없습니다.
>
> - **클라이언트가 호출하는 URL** (트래킹 픽셀, 클릭 URL): 고객이 택배를 열어볼 때 자동으로 발생하는 알림.
>   "고객이 상자를 열었습니다" (노출), "고객이 안내문을 클릭했습니다" (클릭)
>   → 실제로 사용자의 화면에서 일어나는 일이므로, 사용자의 기기가 호출합니다.
>
> **판단 규칙 3가지:**
> 1. 돈이 관련되면 → 서버가 호출 (보안을 위해)
> 2. "사용자가 봤는가/클릭했는가" → 클라이언트가 호출 (사용자 기기만 알 수 있으므로)
> 3. 매크로(${AUCTION_PRICE})가 있으면 → 서버가 치환 (가격은 서버만 알고 있으므로)

---

## 한눈에 보기

```
┌──────────────────────────────────────────────────────────────────┐
│                     호출 주체 총정리                              │
├────────────────┬──────────────┬──────────────┬──────────────────┤
│ URL            │ 호출 주체     │ 시점          │ 목적             │
├────────────────┼──────────────┼──────────────┼──────────────────┤
│ nurl           │ 🖥️ 서버 (SSP) │ 낙찰 직후     │ 낙찰 알림        │
│ burl           │ 🖥️ 서버 (SSP) │ 광고 렌더링 후 │ 과금 트리거      │
│ lurl           │ 🖥️ 서버 (SSP) │ 패찰 시       │ 패찰 알림        │
├────────────────┼──────────────┼──────────────┼──────────────────┤
│ VAST Impression│ 📱 클라이언트  │ 영상 로드 시   │ 노출 트래킹      │
│ VAST Tracking  │ 📱 클라이언트  │ 재생 진행 시   │ 쿼타일 트래킹    │
│ VAST Click     │ 📱 클라이언트  │ 유저 클릭 시   │ 클릭 트래킹      │
├────────────────┼──────────────┼──────────────┼──────────────────┤
│ Banner 픽셀     │ 📱 클라이언트  │ HTML 렌더링 시 │ 노출 트래킹      │
│ Banner 클릭     │ 📱 클라이언트  │ 유저 클릭 시   │ 클릭 트래킹      │
├────────────────┼──────────────┼──────────────┼──────────────────┤
│ Native imptr   │ 📱 클라이언트  │ 광고 노출 시   │ 노출 트래킹      │
│ Native clicktr │ 📱 클라이언트  │ 유저 클릭 시   │ 클릭 트래킹      │
└────────────────┴──────────────┴──────────────┴──────────────────┘

🖥️ = Server-to-Server (SSP 서버 → DSP 서버)
📱 = Client-Side (브라우저/앱/SDK → DSP 서버)
```

---

## 1. 서버가 호출하는 URL (Server-to-Server)

### 1.1 nurl (Win Notice URL)

```
호출 주체: SSP 서버
호출 대상: DSP 서버
시점:      경매 낙찰 직후 (광고 노출 전)
목적:      "당신이 낙찰되었습니다" 알림
과금 여부:  ❌ 아님 (단순 알림)
```

```
경매 종료
    │
    ▼
SSP 서버 ──HTTP GET──→ DSP 서버
    │
    "https://dsp.com/win?id=123&price=2.50"
    │
    ▼
DSP: "아, 낙찰됐구나. 기록해두자."
```

**왜 서버인가?**
- 경매는 SSP 서버에서 실행됨
- 낙찰 결과는 SSP 서버만 알고 있음
- 클라이언트는 아직 광고를 받지도 않은 상태
- `${AUCTION_PRICE}` 매크로를 SSP 서버가 치환해야 함

**주의:**
- nurl 호출 = 광고 노출이 **아님**
- nurl만으로 과금하면 안 됨 (유저가 실제로 광고를 봤는지 모름)
- 일부 DSP는 nurl 응답으로 adm(광고 마크업)을 반환하기도 함 (adm이 비어있을 때)

---

### 1.2 burl (Billing Notice URL)

```
호출 주체: SSP 서버
호출 대상: DSP 서버
시점:      광고가 실제로 렌더링 확인된 후
목적:      "과금하세요" 트리거
과금 여부:  ✅ 과금 기준점
```

```
광고 렌더링 완료 (클라이언트가 SSP에 알림)
    │
    ▼
SSP 서버 ──HTTP GET──→ DSP 서버
    │
    "https://dsp.com/billing?id=123&price=2.50"
    │
    ▼
DSP: "실제 노출 확인. 예산 차감."
```

**왜 서버인가?**
- `${AUCTION_PRICE}` 매크로를 SSP 서버가 치환해야 함
- 과금 금액이 포함되므로 보안상 서버 간 통신이 적절
- 클라이언트 조작 방지 (프론트에서 호출하면 금액 위조 가능)

**burl의 트리거 흐름:**
```
1. 클라이언트: 광고 렌더링 완료
2. 클라이언트 → SSP 서버: "렌더링 됐어요" (SDK 콜백 또는 이벤트)
3. SSP 서버 → DSP 서버: burl 호출 (매크로 치환 포함)
```

> 즉, **클라이언트가 "트리거"하지만, 실제 burl HTTP 호출은 SSP 서버가 한다.**

---

### 1.3 lurl (Loss Notice URL)

```
호출 주체: SSP 서버
호출 대상: DSP 서버
시점:      경매 패찰 확정 시
목적:      "당신이 패찰했습니다" 알림 + 사유 전달
과금 여부:  ❌ 아님
```

```
경매 종료 (이 DSP가 패찰)
    │
    ▼
SSP 서버 ──HTTP GET──→ DSP 서버
    │
    "https://dsp.com/loss?id=123&reason=${AUCTION_LOSS}"
    │
    ▼
DSP: "패찰 사유가 102(가격 부족)이구나. 입찰 전략 조정해야지."
```

**왜 서버인가?**
- 패찰 정보는 SSP 서버만 알고 있음
- 클라이언트에게는 패찰한 DSP의 정보가 전달되지 않음
- `${AUCTION_LOSS}`, `${AUCTION_MIN_TO_WIN}` 등 매크로 치환 필요

---

## 2. 클라이언트가 호출하는 URL (Client-Side)

### 2.1 VAST 내부 URL들 (Video 광고)

Video 광고의 adm은 VAST XML이며, 그 안에 여러 트래킹 URL이 있다.
**이것들은 모두 비디오 플레이어(클라이언트)가 호출한다.**

```xml
<VAST version="3.0">
  <Ad>
    <InLine>
      <!-- 📱 클라이언트 호출: 영상 로드 시 -->
      <Impression><![CDATA[https://dsp.com/imp?id=123]]></Impression>

      <Creatives>
        <Creative>
          <Linear>
            <TrackingEvents>
              <!-- 📱 클라이언트 호출: 재생 진행에 따라 -->
              <Tracking event="start"><![CDATA[https://dsp.com/start]]></Tracking>
              <Tracking event="firstQuartile"><![CDATA[https://dsp.com/25]]></Tracking>
              <Tracking event="midpoint"><![CDATA[https://dsp.com/50]]></Tracking>
              <Tracking event="thirdQuartile"><![CDATA[https://dsp.com/75]]></Tracking>
              <Tracking event="complete"><![CDATA[https://dsp.com/100]]></Tracking>
            </TrackingEvents>

            <VideoClicks>
              <!-- 📱 클라이언트 호출: 유저가 클릭할 때 -->
              <ClickThrough><![CDATA[https://landing.page.com]]></ClickThrough>
              <ClickTracking><![CDATA[https://dsp.com/click]]></ClickTracking>
            </VideoClicks>
          </Linear>
        </Creative>
      </Creatives>
    </InLine>
  </Ad>
</VAST>
```

| VAST 내 URL | 호출 주체 | 시점 | 목적 |
|-------------|----------|------|------|
| `<Impression>` | 📱 비디오 플레이어 | 영상 로드/재생 시작 시 | DSP 노출 집계 |
| `<Tracking event="start">` | 📱 비디오 플레이어 | 재생 시작 시 | 시작 트래킹 |
| `<Tracking event="firstQuartile">` | 📱 비디오 플레이어 | 25% 재생 시 | 진행 트래킹 |
| `<Tracking event="midpoint">` | 📱 비디오 플레이어 | 50% 재생 시 | 진행 트래킹 |
| `<Tracking event="thirdQuartile">` | 📱 비디오 플레이어 | 75% 재생 시 | 진행 트래킹 |
| `<Tracking event="complete">` | 📱 비디오 플레이어 | 100% 재생 시 | 완료 트래킹 |
| `<ClickThrough>` | 📱 비디오 플레이어 | 유저 클릭 시 | 랜딩 페이지 이동 |
| `<ClickTracking>` | 📱 비디오 플레이어 | 유저 클릭 시 | 클릭 트래킹 |

**왜 클라이언트인가?**
- "유저가 영상을 봤는가?" → 비디오 플레이어만 알 수 있음
- "25% 재생했는가?" → 비디오 플레이어만 알 수 있음
- "유저가 클릭했는가?" → 클라이언트 이벤트
- 서버는 유저의 실제 행동을 알 수 없음

---

### 2.2 Banner adm 내부 URL들

Banner 광고의 adm은 HTML이며, 그 안에 트래킹 픽셀과 클릭 URL이 있다.
**브라우저/WebView가 HTML을 렌더링하면서 호출한다.**

```html
<div>
  <!-- 📱 클라이언트 호출: 유저가 클릭할 때 -->
  <a href="https://dsp.com/click?redirect=https://landing.com">
    <img src="https://cdn.com/banner.jpg" width="300" height="250"/>
  </a>

  <!-- 📱 클라이언트 호출: HTML 렌더링 시 (1x1 픽셀 로드) -->
  <img src="https://dsp.com/imp?id=123" width="1" height="1" style="display:none"/>
</div>
```

| Banner 내 URL | 호출 주체 | 시점 | 목적 |
|--------------|----------|------|------|
| 1x1 픽셀 `<img>` | 📱 브라우저/WebView | HTML 렌더링 시 | DSP 노출 집계 |
| `<a href>` 클릭 URL | 📱 브라우저/WebView | 유저 클릭 시 | 클릭 트래킹 + 랜딩 |

**왜 클라이언트인가?**
- HTML 렌더링 = 브라우저의 역할
- 1x1 픽셀은 `<img>` 태그 → 브라우저가 자동으로 HTTP GET
- 클릭은 유저 행동 → 브라우저 이벤트

---

### 2.3 Native 트래킹 URL들

Native 광고의 adm은 JSON이며, 그 안에 트래킹 URL 배열이 있다.
**앱 SDK 또는 렌더러가 호출한다.**

```json
{
  "native": {
    "assets": [...],
    "link": {
      "url": "https://landing.com",
      "clicktrackers": [
        "https://dsp.com/click?id=123"
      ]
    },
    "imptrackers": [
      "https://dsp.com/imp?id=123"
    ],
    "eventtrackers": [
      {
        "event": 1,
        "method": 1,
        "url": "https://dsp.com/viewable?id=123"
      }
    ]
  }
}
```

| Native 내 URL | 호출 주체 | 시점 | 목적 |
|--------------|----------|------|------|
| `imptrackers[]` | 📱 앱 SDK/렌더러 | 광고 렌더링 시 | DSP 노출 집계 |
| `link.clicktrackers[]` | 📱 앱 SDK/렌더러 | 유저 클릭 시 | 클릭 트래킹 |
| `link.url` | 📱 앱 SDK/렌더러 | 유저 클릭 시 | 랜딩 페이지 이동 |
| `eventtrackers[]` | 📱 앱 SDK/렌더러 | 뷰어빌리티 등 | 고급 이벤트 트래킹 |

**왜 클라이언트인가?**
- Native 광고의 렌더링은 앱이 직접 수행 (HTML이 아님)
- 노출/클릭 이벤트는 앱 SDK가 감지
- 서버는 유저가 광고를 봤는지 알 수 없음

---

## 3. SSP가 추가하는 트래킹 URL

SSP도 자체적으로 트래킹이 필요하다. DSP의 URL과 별개로 SSP가 자체 URL을 삽입한다.

```
DSP 원본 adm:
  <img src="https://DSP.com/imp"/>     ← DSP 노출 트래킹

SSP가 추가:
  <img src="https://SSP.com/imp"/>     ← SSP 자체 노출 트래킹
  <img src="https://DSP.com/imp"/>     ← DSP 노출 트래킹 (원본 유지)
```

| SSP 트래킹 | 삽입 위치 | 호출 주체 | 목적 |
|-----------|----------|----------|------|
| SSP Impression 픽셀 | adm에 추가 삽입 | 📱 클라이언트 | SSP 자체 노출 집계 |
| SSP Event URL | SDK 콜백 | 📱 클라이언트 → 🖥️ SSP 서버 | 이벤트 수집 |

---

## 4. 전체 흐름도 (시간 순서)

```
시간 →

[경매]                    [렌더링]              [유저 행동]
  │                         │                      │
  ├─① SSP 서버가 경매 실행    │                      │
  │                         │                      │
  ├─② 낙찰 확정              │                      │
  │  └─🖥️ nurl 호출 (서버)    │                      │
  │  └─🖥️ lurl 호출 (서버)    │                      │
  │     (패찰한 DSP들에게)     │                      │
  │                         │                      │
  ├─③ adm을 클라이언트에 전달  │                      │
  │                         │                      │
  │                    ④ 클라이언트가 adm 렌더링      │
  │                    │                            │
  │                    ├─📱 Banner: 1x1 픽셀 호출     │
  │                    ├─📱 Video: VAST Impression    │
  │                    ├─📱 Native: imptrackers       │
  │                    │                            │
  │                    ├─🖥️ burl 호출 (서버)          │
  │                    │  (SSP가 렌더링 확인 후)       │
  │                    │                            │
  │                    │                       ⑤ 유저가 광고 시청
  │                    │                       │
  │                    │                       ├─📱 Video: 쿼타일 트래킹
  │                    │                       │  (25%, 50%, 75%, 100%)
  │                    │                       │
  │                    │                       ├─📱 유저 클릭 시:
  │                    │                       │  ├─ Banner: <a href> 이동
  │                    │                       │  ├─ Video: ClickThrough
  │                    │                       │  └─ Native: link.url
  │                    │                       │
  │                    │                       └─📱 클릭 트래커 호출
```

---

## 5. 헷갈리기 쉬운 포인트 정리

### Q1: "burl도 클라이언트가 호출하는 거 아닌가요?"

**아니다.** burl은 SSP **서버**가 호출한다.

```
흐름:
1. 클라이언트가 광고를 렌더링한다
2. 클라이언트가 SSP 서버에게 "렌더링 완료" 이벤트를 보낸다
3. SSP 서버가 burl을 호출한다 (매크로 치환 포함)

클라이언트가 burl을 직접 호출하지 않는 이유:
- burl에는 ${AUCTION_PRICE}가 들어있다
- 이 값은 SSP 서버만 알고 있다
- 클라이언트에게 낙찰가를 노출하면 보안 위험
```

### Q2: "nurl과 VAST Impression의 차이는?"

```
nurl (서버):
  시점: 경매 직후 (유저가 광고를 보기 전)
  목적: DSP에게 "낙찰됐어" 알림
  과금: ❌

VAST <Impression> (클라이언트):
  시점: 비디오 플레이어가 영상을 로드/재생할 때
  목적: DSP에게 "유저가 실제로 봤어" 알림
  과금: ✅ (보통 이것이 노출 기준)

결론: 둘 다 "impression"이라는 단어를 쓰지만 완전히 다르다!
  - nurl = "낙찰 통지" (서버)
  - VAST Impression = "실제 노출" (클라이언트)
```

### Q3: "SSP는 클릭을 어떻게 트래킹하나?"

```
배너 (HTML adm):
  문제: adm 안의 <a href>가 DSP URL로 하드코딩
  해결: Click Macro (${CLICK_URL}) 또는 HTML Wrapping

비디오 (VAST):
  해결: SSP가 VAST에 자체 ClickTracking 노드를 추가 삽입

네이티브:
  해결: link.clicktrackers[] 배열에 SSP URL 추가
```

### Q4: "${AUCTION_PRICE}는 누가 치환하나?"

```
항상 SSP 서버가 치환한다.

이유:
- 낙찰가는 SSP 서버만 알고 있다
- 그래서 매크로가 포함된 URL은 반드시 서버가 호출하거나,
  서버가 치환한 후 클라이언트에게 전달한다

매크로가 들어가는 곳:
  nurl → 서버가 치환 후 서버가 호출 ✅
  burl → 서버가 치환 후 서버가 호출 ✅
  lurl → 서버가 치환 후 서버가 호출 ✅
  adm  → 서버가 치환 후 클라이언트에게 전달 ✅
```

### Q5: "adm 안의 URL은 서버가 호출? 클라이언트가 호출?"

```
adm 자체는 SSP 서버가 클라이언트에게 전달하는 "콘텐츠"다.
adm 안에 들어있는 URL들은 클라이언트가 호출한다.

SSP 서버의 역할:
  1. adm 안의 ${AUCTION_PRICE} 등 매크로를 치환
  2. 필요시 SSP 자체 트래킹 픽셀을 adm에 삽입
  3. 치환/삽입 완료된 adm을 클라이언트에게 전달

클라이언트의 역할:
  1. adm을 렌더링 (HTML 표시, VAST 파싱, Native JSON 파싱)
  2. 렌더링 과정에서 트래킹 URL들이 자동 호출됨
```

---

## 6. 구현 체크리스트 (백엔드)

### SSP 서버가 해야 할 것

- [ ] 낙찰 시 `nurl` HTTP GET 호출 (비동기, 실패해도 진행)
- [ ] 패찰 시 `lurl` HTTP GET 호출 (비동기, 실패해도 진행)
- [ ] 렌더링 확인 후 `burl` HTTP GET 호출 (과금 기준!)
- [ ] 위 URL들의 `${AUCTION_PRICE}` 등 매크로 치환
- [ ] adm 내부의 매크로 치환 후 클라이언트에 전달
- [ ] 필요시 adm에 SSP 자체 트래킹 픽셀 삽입

### 클라이언트(SDK/브라우저)가 해야 할 것

- [ ] adm 렌더링 (Banner: HTML, Video: VAST, Native: JSON)
- [ ] 렌더링 완료 시 SSP에 이벤트 전달 → burl 트리거
- [ ] Banner: 1x1 픽셀 자동 로드 (DSP 노출 트래킹)
- [ ] Video: VAST Impression/Tracking URL 호출
- [ ] Native: imptrackers 호출
- [ ] 클릭 시 클릭 트래커 호출 + 랜딩 페이지 이동

---

## 7. 요약 원칙

```
┌─────────────────────────────────────────────────────────────┐
│                     3가지 원칙                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. 매크로(${AUCTION_PRICE})가 들어있으면 → 🖥️ 서버가 치환    │
│                                                             │
│  2. "유저가 봤는가/클릭했는가"를 판단하는 건 → 📱 클라이언트    │
│                                                             │
│  3. "돈"이 관련된 알림(nurl/burl/lurl)은 → 🖥️ 서버 간 통신   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

| 질문 | 답 |
|------|---|
| 매크로 치환이 필요한가? | → 🖥️ 서버 |
| 유저 행동을 감지해야 하는가? | → 📱 클라이언트 |
| 금액 정보가 포함되어 있는가? | → 🖥️ 서버 |
| adm 안에 있는 URL인가? | → 📱 클라이언트 (렌더링 과정에서 호출) |

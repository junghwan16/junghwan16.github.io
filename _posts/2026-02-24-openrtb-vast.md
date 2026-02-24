---
layout: single
title: "OpenRTB에서 VAST 이해하기"
date: 2026-02-24 22:00:00 +0900
categories: [ad-tech, openrtb]
---

OpenRTB에서 **VAST(Video Ad Serving Template)**가 어떻게 전달되고 처리되는지를 정리한 브릿지 문서.

> **💡 Tip: 비유로 이해하기**
> VAST는 비디오 광고의 **레시피**입니다.
>
> 요리 레시피에 "재료 준비 → 볶기 → 양념 → 완성" 순서가 적혀 있듯이,
> VAST에는 이런 순서가 적혀 있습니다:
> 1. "이 URL에서 영상 파일을 다운로드하세요" (MediaFile)
> 2. "영상이 시작되면 이 URL에 알려주세요" (Impression)
> 3. "25% 재생되면 이 URL, 50%면 이 URL..." (TrackingEvents)
> 4. "사용자가 광고를 클릭하면 이 페이지로 보내세요" (ClickThrough)
>
> 비디오 플레이어는 이 레시피를 받아서 순서대로 실행합니다.
> 그래서 VAST를 "Video Ad **Serving** Template"이라고 부릅니다 - 영상 광고를 어떻게 제공할지 정의하는 템플릿이니까요.

---

## 1. VAST는 어디에 들어가는가?

비디오 광고에서 DSP는 VAST XML을 **`bid.adm`** 필드에 문자열로 넣어서 반환한다.

```
BidResponse
  └── seatbid[]
        └── bid[]
              ├── adm: "<?xml version=\"1.0\"?><VAST version=\"4.0\">...</VAST>"
              ├── nurl: "https://dsp.com/win?price=${AUCTION_PRICE}"
              └── mtype: 2  (Video)
```

| 필드 | 역할 |
|------|------|
| `adm` | VAST XML 전체가 문자열로 들어감 |
| `mtype` | `2` = Video (OpenRTB 2.6) |
| `nurl` | Win Notice — adm이 비어있으면 nurl 응답으로 VAST 반환 가능 |

> **💡 Tip: adm vs nurl 방식**
> - **adm 방식 (인라인)**: VAST XML이 bid response에 바로 포함. 빠르지만 응답 크기 증가.
> - **nurl 방식 (프록시)**: adm이 비어있고, SSP가 nurl을 호출하면 DSP가 VAST XML을 응답으로 반환. 대역폭 절약되지만 추가 네트워크 hop 발생.

---

## 2. protocols 필드 — VAST 버전 협상

BidRequest의 `video.protocols` 필드로 SSP가 지원하는 VAST 버전을 DSP에게 알린다.

```json
{
  "imp": [{
    "video": {
      "protocols": [2, 3, 5, 6],
      "mimes": ["video/mp4"],
      "minduration": 5,
      "maxduration": 30
    }
  }]
}
```

| 값 | 의미 |
|----|------|
| `1` | VAST 1.0 |
| `2` | VAST 2.0 |
| `3` | VAST 3.0 |
| `4` | VAST 1.0 Wrapper |
| `5` | VAST 2.0 Wrapper |
| `6` | VAST 3.0 Wrapper |
| `7` | VAST 4.0 |
| `8` | VAST 4.0 Wrapper |
| `11` | VAST 4.2 |
| `12` | VAST 4.2 Wrapper |

> **Note: Wrapper란?**
> VAST Wrapper는 실제 미디어 파일 대신 **다른 VAST URL을 가리키는 래핑 문서**다. 여러 단계의 리다이렉트를 통해 최종 미디어와 트래킹 URL을 수집한다. SSP는 보통 Wrapper chain depth를 3~5로 제한한다.

---

## 3. 비디오 광고의 전체 라이프사이클

```
1. SSP → DSP: BidRequest (video.protocols, mimes, duration 포함)
2. DSP → SSP: BidResponse (adm에 VAST XML 포함)
3. SSP → DSP: nurl 호출 (Win Notice, 서버 간)
4. SSP → 클라이언트: VAST XML 전달
5. 클라이언트:
   ├── VAST 파싱 → MediaFile URL에서 비디오 다운로드
   ├── <Impression> 픽셀 호출 (비디오 재생 시작 시)
   ├── <TrackingEvents> 호출:
   │   ├── start (재생 시작)
   │   ├── firstQuartile (25%)
   │   ├── midpoint (50%)
   │   ├── thirdQuartile (75%)
   │   └── complete (100%)
   └── <VideoClicks>:
       ├── ClickThrough → 랜딩 페이지 이동
       └── ClickTracking → 클릭 트래커 호출
6. SSP: burl 호출 (Billing Notice, 서버 간, 노출 확인 후)
```

### 호출 주체 정리

| 이벤트 | 호출 주체 | 호출 대상 | 타이밍 |
|--------|-----------|-----------|--------|
| **nurl** | SSP 서버 | DSP 서버 | 옥션 낙찰 직후 |
| **burl** | SSP 서버 | DSP 서버 | 클라이언트 노출 확인 후 |
| **VAST `<Impression>`** | 클라이언트 | DSP 트래커 | 비디오 재생 시작 |
| **VAST TrackingEvents** | 클라이언트 | DSP 트래커 | 재생 진행률에 따라 |
| **VAST ClickThrough** | 클라이언트 | 랜딩 페이지 | 사용자 클릭 시 |
| **VAST ClickTracking** | 클라이언트 | DSP 트래커 | 사용자 클릭 시 |

> **⚠️ 주의: nurl ≠ VAST Impression**
> - **nurl**: 서버 간 호출. "옥션에서 이겼다"는 알림. 사용자가 광고를 봤는지와 무관.
> - **VAST `<Impression>`**: 클라이언트 호출. "사용자가 실제로 비디오를 재생했다"는 확인.
>
> 이 둘을 혼동하면 노출 수 집계가 맞지 않는다.

---

## 4. SSP가 비디오 트래커를 삽입하는 방법

VAST XML은 구조화된 포맷이라 SSP가 자체 트래커를 삽입하기 **쉽다**.

```xml
<!-- DSP가 보낸 원본 VAST -->
<VAST version="4.0">
  <Ad>
    <InLine>
      <Impression><![CDATA[https://dsp-tracker.com/imp]]></Impression>
      <!-- SSP가 여기에 자체 Impression 트래커 추가 -->
      <Impression><![CDATA[https://ssp-tracker.com/imp?id=123]]></Impression>

      <Creatives>
        <Creative>
          <Linear>
            <TrackingEvents>
              <Tracking event="start"><![CDATA[https://dsp.com/start]]></Tracking>
              <!-- SSP 트래커 추가 가능 -->
              <Tracking event="start"><![CDATA[https://ssp.com/start]]></Tracking>
            </TrackingEvents>
            <VideoClicks>
              <ClickThrough><![CDATA[https://landing.com]]></ClickThrough>
              <ClickTracking><![CDATA[https://dsp.com/click]]></ClickTracking>
              <!-- SSP 클릭 트래커 추가 가능 -->
              <ClickTracking><![CDATA[https://ssp.com/click]]></ClickTracking>
            </VideoClicks>
          </Linear>
        </Creative>
      </Creatives>
    </InLine>
  </Ad>
</VAST>
```

| 트래킹 | 삽입 난이도 | 방법 |
|--------|------------|------|
| Impression | 쉬움 | `<Impression>` 태그 추가 |
| 재생 진행률 | 쉬움 | `<Tracking event="...">` 태그 추가 |
| 클릭 | 쉬움 | `<ClickTracking>` 태그 추가 |

> **💡 Tip: Banner와의 차이**
> Banner(HTML)는 `<a href>`가 하드코딩되어 SSP 클릭 트래커 삽입이 어렵지만, VAST는 `<ClickTracking>` 태그를 추가하기만 하면 된다.

---

## 5. 주의사항

### Wrapper Chain Depth

```
VAST Wrapper A → Wrapper B → Wrapper C → InLine (실제 미디어)
```

체인이 길수록 레이턴시 증가. SSP는 보통 **3~5단계**로 제한하고, 초과 시 폐기.

### VPAID vs VAST

| 구분 | VAST | VPAID |
|------|------|-------|
| 역할 | 비디오 전달/트래킹 포맷 | 인터랙티브 실행 환경 |
| 보안 | 안전 (XML만) | 위험 (JS 실행) |
| 추세 | 유지 | **폐기 중** (SIMID로 대체) |

### 매크로 치환

VAST XML 내에도 OpenRTB 매크로가 사용될 수 있다:

```xml
<Impression>
  <![CDATA[https://dsp.com/imp?price=${AUCTION_PRICE}&id=${AUCTION_ID}]]>
</Impression>
```

SSP 서버가 VAST XML을 클라이언트에 전달하기 전에 매크로를 치환해야 한다.

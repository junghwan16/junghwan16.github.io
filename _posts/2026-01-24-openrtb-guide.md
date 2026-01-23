---
layout: post
title: "OpenRTB 연동할 때 알아야 할 것들"
date: 2026-01-24 20:00:00 +0900
categories: [adtech, openrtb]
---

OpenRTB(Open Real-Time Bidding)는 프로그래매틱 광고에서 SSP와 DSP 간의 통신을 위한 IAB 표준 프로토콜입니다. 처음 연동하면 BidRequest/BidResponse 구조, 광고 타입별 차이점이 헷갈리기 쉽습니다. 실제 예시와 함께 정리합니다.

## 먼저 생각해볼 것

> - SSP 연동인가, DSP 연동인가?
> - 어떤 광고 타입(Banner, Native, Video)을 지원해야 하는가?
> - 상대방이 지원하는 OpenRTB 버전은 무엇인가?

## OpenRTB 기본 흐름

```
사용자가 앱/웹 방문
        ↓
퍼블리셔 → SSP: 광고 요청
        ↓
SSP → DSP: BidRequest (JSON)
        ↓
DSP → SSP: BidResponse (JSON)
        ↓
SSP: 경매 진행 (1st/2nd Price)
        ↓
낙찰된 광고 노출
```

## BidRequest 구조

SSP가 DSP에게 "이런 광고 지면이 있어요"라고 알려주는 요청입니다.

### 기본 구조

```json
{
  "id": "request-123",
  "imp": [{
    "id": "imp-456",
    "bidfloor": 0.5,
    "banner": { ... },
    "video": { ... },
    "native": { ... }
  }],
  "site": {
    "id": "site-789",
    "domain": "example.com",
    "cat": ["IAB1"]
  },
  "device": {
    "ua": "Mozilla/5.0...",
    "ip": "192.168.1.1",
    "geo": {
      "country": "KOR",
      "city": "Seoul"
    }
  },
  "user": {
    "id": "user-abc"
  }
}
```

### 주요 필드

| 필드 | 설명 |
|------|------|
| `id` | 요청 고유 ID |
| `imp` | Impression 배열 (광고 지면 정보) |
| `imp[].bidfloor` | 최소 입찰가 (CPM) |
| `site` / `app` | 웹사이트 또는 앱 정보 |
| `device` | 디바이스 정보 (UA, IP, 위치 등) |
| `user` | 사용자 정보 |

### 자가 체크

> - `imp[].bidfloor` 값을 확인하고 있는가? 이 가격 이하로 입찰하면 낙찰되지 않는다
> - `site`와 `app` 중 어느 필드가 들어오는지 확인했는가? (웹 vs 앱)
> - `device.geo` 정보로 지역 타겟팅을 해야 하는가?

---

## BidResponse 구조

DSP가 SSP에게 "이 광고로 입찰합니다"라고 응답합니다.

### 기본 구조

```json
{
  "id": "response-123",
  "seatbid": [{
    "seat": "advertiser-nike",
    "bid": [{
      "id": "bid-123",
      "impid": "imp-456",
      "price": 2.5,
      "adm": "<광고 마크업>",
      "nurl": "https://dsp.com/win?price=${AUCTION_PRICE}",
      "adomain": ["advertiser.com"],
      "crid": "creative-789",
      "w": 300,
      "h": 250
    }]
  }]
}
```

### 주요 필드

| 필드 | 설명 |
|------|------|
| `impid` | BidRequest의 `imp.id`와 매칭 |
| `price` | CPM 입찰가 (1000회 노출당 가격) |
| `adm` | 광고 마크업 (HTML, VAST XML 등) |
| `nurl` | Win Notice URL (낙찰 시 호출) |
| `adomain` | 광고주 도메인 |
| `crid` | 크리에이티브 ID |

### SeatBid: 왜 여러 개인가?

하나의 DSP가 **여러 광고주**를 대신해 동시에 입찰할 수 있습니다.

```json
{
  "seatbid": [
    {
      "seat": "advertiser-nike",
      "bid": [{ "price": 3.0, "adm": "나이키 광고" }]
    },
    {
      "seat": "advertiser-adidas",
      "bid": [{ "price": 2.5, "adm": "아디다스 광고" }]
    }
  ]
}
```

SSP는 `seat` 정보로 **특정 광고주만 필터링**하거나 **광고주별 리포팅**이 가능합니다.

### nurl 매크로

낙찰 시 SSP가 nurl을 호출하며, 매크로를 실제 값으로 치환합니다.

```
https://dsp.com/win?price=${AUCTION_PRICE}&bid=${AUCTION_BID_ID}
        ↓ 치환
https://dsp.com/win?price=2.11&bid=bid-123
```

| 매크로 | 의미 |
|--------|------|
| `${AUCTION_PRICE}` | 실제 낙찰가 |
| `${AUCTION_BID_ID}` | 입찰 ID |
| `${AUCTION_IMP_ID}` | Impression ID |

### 자가 체크

> - `impid`가 BidRequest의 `imp.id`와 정확히 매칭되는가?
> - `nurl`에서 `${AUCTION_PRICE}` 매크로를 올바르게 파싱하고 있는가?
> - `adomain`에 실제 광고주 도메인이 들어가 있는가? (블랙리스트 필터링에 사용됨)

---

## 광고 타입별 상세

### 1. Banner 광고

가장 기본적인 이미지/HTML 배너 광고입니다.

#### BidRequest

```json
{
  "imp": [{
    "id": "imp-456",
    "banner": {
      "w": 300,
      "h": 250,
      "format": [
        {"w": 300, "h": 250},
        {"w": 320, "h": 50}
      ],
      "pos": 1,
      "mimes": ["image/jpeg", "image/png", "text/html"]
    }
  }]
}
```

| 필드 | 설명 |
|------|------|
| `w`, `h` | 배너 크기 (픽셀) |
| `format` | 지원하는 크기 목록 |
| `pos` | 광고 위치 (1=Above the fold, 3=Below the fold 등) |
| `mimes` | 지원 MIME 타입 |

#### BidResponse (adm)

```html
<a href="https://advertiser.com/landing">
  <img src="https://cdn.dsp.com/banner.jpg" width="300" height="250">
</a>
<img src="https://dsp.com/impression?id=123" width="1" height="1">
```

### 자가 체크

> - Banner 응답의 `w`, `h`가 BidRequest의 `format`에 포함된 크기인가?
> - Impression 트래킹용 1x1 픽셀을 adm에 포함했는가?

---

### 2. Native 광고

앱/웹의 콘텐츠에 자연스럽게 녹아드는 광고입니다.

#### BidRequest

```json
{
  "imp": [{
    "native": {
      "request": "{\"assets\":[...]}"
    }
  }]
}
```

`request` 필드 안에 JSON 문자열로 **필요한 에셋**을 정의합니다.

#### Native Request (assets 상세)

```json
{
  "assets": [
    {
      "id": 1,
      "required": 1,
      "title": { "len": 50 }
    },
    {
      "id": 2,
      "required": 1,
      "img": {
        "type": 3,
        "wmin": 300,
        "hmin": 250
      }
    },
    {
      "id": 3,
      "required": 1,
      "data": {
        "type": 2,
        "len": 150
      }
    },
    {
      "id": 4,
      "required": 1,
      "data": {
        "type": 12,
        "len": 15
      }
    }
  ]
}
```

#### Data Asset 타입

| Type ID | 이름 | 설명 | 예시 |
|---------|------|------|------|
| 1 | Sponsored | 광고주명 | "Samsung" |
| 2 | DESC | 설명 | "최신 AI 기술로..." |
| 3 | Rating | 평점 | "4.5" |
| 4 | Likes | 좋아요 수 | "12k" |
| 5 | Downloads | 다운로드 수 | "100만+" |
| 6 | Price | 가격 | "$99.99" |
| 7 | Sale Price | 할인가 | "$49.99" |
| 12 | CTA Text | 버튼 텍스트 | "설치하기" |

#### Image Asset 타입

| Type ID | 이름 | 설명 |
|---------|------|------|
| 1 | Icon | 앱 아이콘 (작은 이미지) |
| 3 | Main | 메인 이미지 (큰 이미지) |

#### Native Response

```json
{
  "native": {
    "assets": [
      { "id": 1, "title": { "text": "신제품 출시!" } },
      { "id": 2, "img": { "url": "https://cdn.dsp.com/main.jpg", "w": 300, "h": 250 } },
      { "id": 3, "data": { "type": 2, "value": "혁신적인 기능을 경험하세요." } },
      { "id": 4, "data": { "type": 12, "value": "자세히 보기" } }
    ],
    "link": { "url": "https://advertiser.com/landing" },
    "imptrackers": ["https://dsp.com/impression?id=123"]
  }
}
```

### 자가 체크

> - BidRequest의 `required: 1`인 asset을 모두 응답에 포함했는가?
> - 응답의 asset id가 요청의 asset id와 매칭되는가?
> - `data.type` 값이 요청에서 요구한 타입과 일치하는가?

---

### 3. Video 광고 (VAST)

비디오 광고는 **VAST (Video Ad Serving Template)** 표준을 사용합니다.

#### BidRequest

```json
{
  "imp": [{
    "video": {
      "mimes": ["video/mp4", "video/webm"],
      "minduration": 5,
      "maxduration": 30,
      "protocols": [2, 3, 5, 6, 7],
      "w": 640,
      "h": 360,
      "linearity": 1,
      "placement": 1
    }
  }]
}
```

| 필드 | 설명 |
|------|------|
| `mimes` | 지원 MIME 타입 |
| `minduration` / `maxduration` | 광고 길이 (초) |
| `protocols` | 지원 VAST 버전 |
| `linearity` | 1=Linear(인스트림), 2=Non-linear(오버레이) |
| `placement` | 광고 위치 유형 |

#### protocols 값

| 값 | 의미 |
|----|------|
| 2 | VAST 2.0 |
| 3 | VAST 3.0 |
| 5 | VAST 2.0 Wrapper |
| 6 | VAST 3.0 Wrapper |
| 7 | VAST 4.0 |

#### placement 값

| 값 | 의미 | 설명 |
|----|------|------|
| 1 | In-Stream | 프리롤, 미드롤, 포스트롤 |
| 2 | In-Banner | 배너 영역에서 재생 |
| 3 | In-Article | 기사 본문 내 |
| 4 | In-Feed | 피드 내 |
| 5 | Interstitial | 전면 광고 |

#### BidResponse (adm = VAST XML)

```xml
<VAST version="4.0">
  <Ad id="ad-123">
    <InLine>
      <AdSystem>DSP Name</AdSystem>
      <AdTitle>광고 제목</AdTitle>

      <!-- 노출 트래킹 -->
      <Impression><![CDATA[https://dsp.com/impression?id=123]]></Impression>

      <!-- 에러 트래킹 -->
      <Error><![CDATA[https://dsp.com/error?code=[ERRORCODE]]]></Error>

      <Creatives>
        <Creative id="creative-456">
          <Linear>
            <Duration>00:00:15</Duration>

            <!-- 재생 진행률 트래킹 -->
            <TrackingEvents>
              <Tracking event="start"><![CDATA[https://dsp.com/track?e=start]]></Tracking>
              <Tracking event="firstQuartile"><![CDATA[https://dsp.com/track?e=25]]></Tracking>
              <Tracking event="midpoint"><![CDATA[https://dsp.com/track?e=50]]></Tracking>
              <Tracking event="thirdQuartile"><![CDATA[https://dsp.com/track?e=75]]></Tracking>
              <Tracking event="complete"><![CDATA[https://dsp.com/track?e=100]]></Tracking>
            </TrackingEvents>

            <!-- 비디오 파일 (여러 해상도) -->
            <MediaFiles>
              <MediaFile delivery="progressive" type="video/mp4"
                         width="1280" height="720" bitrate="2000">
                <![CDATA[https://cdn.dsp.com/video_720p.mp4]]>
              </MediaFile>
              <MediaFile delivery="progressive" type="video/mp4"
                         width="640" height="360" bitrate="800">
                <![CDATA[https://cdn.dsp.com/video_360p.mp4]]>
              </MediaFile>
            </MediaFiles>

            <!-- 클릭 처리 -->
            <VideoClicks>
              <ClickThrough><![CDATA[https://advertiser.com/landing]]></ClickThrough>
              <ClickTracking><![CDATA[https://dsp.com/click?id=123]]></ClickTracking>
            </VideoClicks>
          </Linear>
        </Creative>
      </Creatives>
    </InLine>
  </Ad>
</VAST>
```

#### VAST 핵심 요소

| 요소 | 역할 |
|------|------|
| `Impression` | 노출 시 호출 (여러 개 가능) |
| `TrackingEvents` | 재생 진행률별 트래킹 |
| `MediaFiles` | 비디오 URL (해상도별 제공) |
| `ClickThrough` | 클릭 시 랜딩 URL |
| `ClickTracking` | 클릭 트래킹 URL |

#### TrackingEvents 이벤트

| 이벤트 | 시점 |
|--------|------|
| `start` | 재생 시작 |
| `firstQuartile` | 25% |
| `midpoint` | 50% |
| `thirdQuartile` | 75% |
| `complete` | 100% |

#### InLine vs Wrapper

| | InLine | Wrapper |
|--|--------|---------|
| 비디오 정보 | 직접 포함 | 다른 VAST 참조 |
| 레이턴시 | 빠름 | 체이닝만큼 느림 |
| 용도 | 최종 광고 | 중간 트래킹 삽입 |

```
Wrapper 체이닝 예시:

Player → SSP VAST (Wrapper)
              ↓
         DSP VAST (Wrapper)
              ↓
         최종 VAST (InLine) ← 실제 비디오
```

### 자가 체크

> - BidRequest의 `protocols`에 포함된 VAST 버전으로 응답하고 있는가?
> - `minduration`과 `maxduration` 범위 내의 광고를 응답하고 있는가?
> - TrackingEvents(start, complete 등)를 모두 구현했는가?
> - Wrapper 체이닝이 너무 깊어지면 타임아웃이 발생할 수 있다. 몇 단계까지 허용하는가?

---

## 낙찰 vs 노출

| 시점 | 트래킹 | 위치 |
|------|--------|------|
| **낙찰 시** | `nurl` 호출 | BidResponse |
| **실제 노출 시** | `Impression` URL 호출 | 광고 마크업 내부 |

빌링 기준을 어느 시점으로 할지 연동 시 협의가 필요합니다.

---

## 정리

| 광고 타입 | adm 내용 | 특징 |
|----------|----------|------|
| **Banner** | HTML/이미지 | 가장 단순, 고정 크기 |
| **Native** | JSON (assets) | 콘텐츠에 자연스럽게 녹아듦 |
| **Video** | VAST XML | 재생 트래킹, Wrapper 체이닝 |

OpenRTB는 프로그래매틱 광고의 핵심 프로토콜입니다. 실제 연동 시에는 SSP/DSP 간 지원하는 필드와 버전을 사전에 확인하는 것이 중요합니다.

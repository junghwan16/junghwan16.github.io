---
layout: single
title: "OpenRTB 미디어 타입별 트래킹 완전 정리"
date: 2026-02-24 21:00:00 +0900
categories: [ad-tech, openrtb]
---

> Banner, Video, Native 각각의 adm 구조, 노출/클릭 트래킹 방식, SSP가 자체 트래커를 붙이는 방법을 완전 정리.
> 특히 **Banner에서 SSP 클릭 트래킹이 어려운 이유와 해결책**을 상세히 다룬다.

> **💡 Tip: 비유로 이해하기**
> 광고주는 "내 광고가 실제로 보여졌는지, 클릭되었는지"를 알고 싶어합니다.
> 이것을 트래킹이라고 합니다.
>
> 세 종류의 광고가 트래킹 방식이 다른 이유를 편지에 비유해 볼까요?
>
> - **Native (네이티브)**: 조립식 편지. 봉투 안에 "읽으면 이 번호로 전화해줘" 메모가 따로 들어있습니다.
>   → SSP가 메모를 하나 더 넣으면 됩니다. **가장 쉽습니다.**
>
> - **Video (비디오)**: 레시피 형식 편지. "재생 시작하면 여기 연락, 25%면 여기 연락..."
>   → SSP가 연락처를 하나 더 적어 넣으면 됩니다. **쉽습니다.**
>
> - **Banner (배너)**: 이미 완성된 포스터. 클릭 링크가 포스터에 인쇄되어 있습니다.
>   → SSP가 이미 인쇄된 포스터를 수정하기 어렵습니다. **이것이 이 문서의 핵심 주제입니다.**

---

## 한눈에 비교

| | Banner | Video | Native |
|--|--------|-------|--------|
| **mtype** | 1 | 2 | 4 |
| **adm 포맷** | HTML/JS 문자열 | VAST XML | JSON 문자열 |
| **노출 트래킹** | 1x1 픽셀 `<img>` | `<Impression>` 태그 | `imptrackers[]` 배열 |
| **클릭 트래킹** | `<a href>` 하드코딩 | `<ClickTracking>` 태그 | `clicktrackers[]` 배열 |
| **SSP 노출 삽입** | 쉬움 (픽셀 추가) | 쉬움 (태그 추가) | 쉬움 (배열에 추가) |
| **SSP 클릭 삽입** | **어려움** | 쉬움 (태그 추가) | 쉬움 (배열에 추가) |
| **SSP 클릭 난이도** | **상** | 하 | 하 |

---

## 1. Native (가장 깔끔한 구조)

### 1.1 adm 구조

Native의 adm은 **구조화된 JSON**이다. 데이터와 트래킹이 명확하게 분리되어 있다.

```json
{
  "native": {
    "ver": "1.2",
    "assets": [
      { "id": 1, "title": { "text": "나이키 신상 운동화" } },
      { "id": 2, "img": { "url": "https://cdn.com/main.jpg", "w": 1200, "h": 627 } },
      { "id": 3, "img": { "url": "https://cdn.com/icon.png", "w": 80, "h": 80, "type": 1 } },
      { "id": 4, "data": { "type": 2, "value": "지금 바로 구매하세요" } },
      { "id": 5, "data": { "type": 12, "value": "구매하기" } }
    ],
    "link": {
      "url": "https://landing.nike.com/shoes",
      "clicktrackers": [
        "https://dsp.com/click?id=123",
        "https://thirdparty.com/click?id=456"
      ]
    },
    "imptrackers": [
      "https://dsp.com/imp?id=123",
      "https://thirdparty.com/imp?id=456"
    ],
    "eventtrackers": [
      { "event": 1, "method": 1, "url": "https://dsp.com/viewable?id=123" }
    ]
  }
}
```

### 1.2 렌더링 방식

앱/SDK가 JSON을 파싱하여 **네이티브 UI 컴포넌트**로 렌더링한다. HTML이 아님.

```
┌─────────────────────────────────────────────┐
│  피드                                        │
│  ┌─────────────────────────────────────┐    │
│  │  Sponsored · nike.com                │    │
│  │  ┌─────────────────────────────┐    │    │
│  │  │                             │    │    │
│  │  │  [메인 이미지: main.jpg]     │    │    │ ← assets[1].img
│  │  │                             │    │    │
│  │  └─────────────────────────────┘    │    │
│  │  나이키 신상 운동화                  │    │ ← assets[0].title
│  │  지금 바로 구매하세요                │    │ ← assets[3].data
│  │  [구매하기]                         │    │ ← assets[4].data (CTA)
│  └─────────────────────────────────────┘    │
│  일반 피드...                                │
└─────────────────────────────────────────────┘
```

### 1.3 노출 트래킹

```
광고가 화면에 렌더링됨
    │
    ▼
SDK가 imptrackers[] 배열의 모든 URL을 HTTP GET 호출
    ├── https://dsp.com/imp?id=123
    └── https://thirdparty.com/imp?id=456
```

**SSP가 자체 노출 트래커를 추가하려면:**
```json
"imptrackers": [
  "https://dsp.com/imp?id=123",
  "https://ssp.com/imp?id=789"
]
```

> **결론: 배열에 URL 하나 push하면 됨. 매우 쉬움.**

### 1.4 클릭 트래킹

```
유저가 광고 영역 아무 데나 탭
    │
    ▼
SDK가 두 가지를 동시에 수행:
    ├── 1. clicktrackers[] 배열의 모든 URL을 HTTP GET 호출
    │      ├── https://dsp.com/click?id=123
    │      └── https://thirdparty.com/click?id=456
    │
    └── 2. link.url로 랜딩 페이지 이동
           └── https://landing.nike.com/shoes
```

**SSP가 자체 클릭 트래커를 추가하려면:**
```json
"clicktrackers": [
  "https://dsp.com/click?id=123",
  "https://ssp.com/click?id=789"
]
```

> **결론: 배열에 URL 하나 push하면 됨. 매우 쉬움.**

### 1.5 Native가 트래킹에 유리한 이유

```
Native의 설계 철학:
  "데이터와 트래킹을 분리하자"

결과:
  - assets[] = 광고 콘텐츠 (이미지, 텍스트, CTA)
  - link = 클릭 목적지 + 클릭 트래커 배열
  - imptrackers = 노출 트래커 배열

SSP든 DSP든 제3자든 트래커를 "배열에 추가"만 하면 된다.
중간자가 몇 명이든 상관없다.
```

---

## 2. Video (VAST XML 기반)

### 2.1 adm 구조

Video의 adm은 **VAST XML**이다. 트래킹이 XML 태그로 구조화되어 있다.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<VAST version="3.0">
  <Ad id="12345">
    <InLine>
      <AdSystem>DSP Name</AdSystem>
      <AdTitle>나이키 동영상 광고</AdTitle>

      <!-- 노출 트래킹 (여러 개 가능) -->
      <Impression><![CDATA[https://dsp.com/imp?id=123]]></Impression>
      <Impression><![CDATA[https://thirdparty.com/imp?id=456]]></Impression>

      <Creatives>
        <Creative>
          <Linear>
            <Duration>00:00:15</Duration>

            <!-- 재생 진행 트래킹 -->
            <TrackingEvents>
              <Tracking event="start"><![CDATA[https://dsp.com/start]]></Tracking>
              <Tracking event="firstQuartile"><![CDATA[https://dsp.com/25pct]]></Tracking>
              <Tracking event="midpoint"><![CDATA[https://dsp.com/50pct]]></Tracking>
              <Tracking event="thirdQuartile"><![CDATA[https://dsp.com/75pct]]></Tracking>
              <Tracking event="complete"><![CDATA[https://dsp.com/100pct]]></Tracking>
              <Tracking event="skip"><![CDATA[https://dsp.com/skip]]></Tracking>
            </TrackingEvents>

            <!-- 클릭 트래킹 -->
            <VideoClicks>
              <ClickThrough><![CDATA[https://landing.nike.com]]></ClickThrough>
              <ClickTracking><![CDATA[https://dsp.com/click?id=123]]></ClickTracking>
              <ClickTracking><![CDATA[https://thirdparty.com/click]]></ClickTracking>
            </VideoClicks>

            <!-- 미디어 파일 -->
            <MediaFiles>
              <MediaFile type="video/mp4" width="640" height="360" bitrate="2000">
                <![CDATA[https://cdn.com/video.mp4]]>
              </MediaFile>
            </MediaFiles>
          </Linear>
        </Creative>
      </Creatives>
    </InLine>
  </Ad>
</VAST>
```

### 2.2 렌더링 방식

비디오 플레이어가 VAST XML을 파싱하여 재생한다.

```
┌─────────────────────────────────────┐
│          Video Player               │
│  ┌─────────────────────────────┐   │
│  │                             │   │
│  │     [나이키 영상 재생중]      │   │
│  │                             │   │
│  └─────────────────────────────┘   │
│  ▶ ━━━━━━━━━━━━━━ 0:07/0:15       │
│                          [Skip Ad] │
│  Learn More                        │
└─────────────────────────────────────┘
```

### 2.3 노출 트래킹

```
비디오 플레이어가 VAST를 로드하고 재생 시작
    │
    ▼
모든 <Impression> 태그의 URL을 HTTP GET 호출
    ├── https://dsp.com/imp?id=123
    └── https://thirdparty.com/imp?id=456
```

**SSP가 자체 노출 트래커를 추가하려면:**
```xml
<!-- SSP가 <Impression> 태그를 하나 더 추가 -->
<Impression><![CDATA[https://dsp.com/imp?id=123]]></Impression>
<Impression><![CDATA[https://ssp.com/imp?id=789]]></Impression>
```

> **결론: XML에 `<Impression>` 태그 하나 추가하면 됨. 쉬움.**

### 2.4 클릭 트래킹

```
유저가 비디오 위의 CTA 버튼 클릭
    │
    ▼
비디오 플레이어가 두 가지를 수행:
    ├── 1. 모든 <ClickTracking> URL을 HTTP GET 호출
    │      ├── https://dsp.com/click?id=123
    │      └── https://thirdparty.com/click
    │
    └── 2. <ClickThrough> URL로 랜딩 페이지 이동
           └── https://landing.nike.com
```

**SSP가 자체 클릭 트래커를 추가하려면:**
```xml
<VideoClicks>
  <ClickThrough><![CDATA[https://landing.nike.com]]></ClickThrough>
  <ClickTracking><![CDATA[https://dsp.com/click?id=123]]></ClickTracking>
  <ClickTracking><![CDATA[https://ssp.com/click?id=789]]></ClickTracking>
</VideoClicks>
```

> **결론: XML에 `<ClickTracking>` 태그 하나 추가하면 됨. 쉬움.**

### 2.5 쿼타일 트래킹 (Video 전용)

Video만의 고유한 트래킹. 재생 진행률에 따라 호출된다.

```
재생 시작 ──→ 25% ──→ 50% ──→ 75% ──→ 100%
   │           │       │       │        │
   start    firstQ  midpoint thirdQ  complete
```

**SSP가 자체 쿼타일 트래커를 추가하려면:**
```xml
<TrackingEvents>
  <Tracking event="start"><![CDATA[https://dsp.com/start]]></Tracking>
  <Tracking event="start"><![CDATA[https://ssp.com/start]]></Tracking>
  <!-- 같은 event에 여러 URL 가능 -->
</TrackingEvents>
```

> **결론: 같은 event 이름으로 `<Tracking>` 태그를 추가하면 됨. 쉬움.**

---

## 3. Banner (SSP 클릭 트래킹이 어려운 유일한 타입)

### 3.1 adm 구조

Banner의 adm은 **HTML/JS 문자열**이다. 구조화되어 있지 않다.

```html
<div id="ad-container">
  <a href="https://dsp.com/click?campaign=abc&redirect=https://landing.nike.com">
    <img src="https://cdn.com/banner_300x250.jpg" width="300" height="250"/>
  </a>
  <img src="https://dsp.com/imp?id=123" width="1" height="1" style="display:none"/>
</div>
```

### 3.2 렌더링 방식

브라우저/WebView가 HTML을 그대로 렌더링한다.

```
┌─────────────────────┐
│   웹페이지           │
│                     │
│   ┌───────────────┐ │
│   │               │ │
│   │  [나이키 배너] │ │ ← <img> 태그
│   │   300x250     │ │
│   │               │ │
│   └───────────────┘ │
│                     │
│   콘텐츠...         │
└─────────────────────┘
```

### 3.3 노출 트래킹

```
브라우저가 HTML을 렌더링
    │
    ▼
1x1 픽셀 <img> 태그를 만나면 자동으로 HTTP GET 호출
    └── https://dsp.com/imp?id=123
```

**SSP가 자체 노출 트래커를 추가하려면:**
```html
<!-- SSP가 adm HTML에 1x1 픽셀을 하나 더 삽입 -->
<img src="https://dsp.com/imp?id=123" width="1" height="1" style="display:none"/>
<img src="https://ssp.com/imp?id=789" width="1" height="1" style="display:none"/>
```

> **결론: HTML에 `<img>` 태그 하나 삽입하면 됨. 쉬움.**

### 3.4 클릭 트래킹 - 여기가 문제!

```
유저가 배너를 클릭
    │
    ▼
브라우저가 <a href="..."> 의 URL로 바로 이동
    └── https://dsp.com/click?campaign=abc&redirect=https://landing.nike.com

문제: SSP가 이 클릭을 알 수 있는 방법이 없다!
```

**왜 어려운가?**

```
Native:  clicktrackers: ["dsp.com/click", "ssp.com/click"]  ← 배열, 추가 가능
Video:   <ClickTracking>dsp.com/click</ClickTracking>       ← 태그, 추가 가능
         <ClickTracking>ssp.com/click</ClickTracking>

Banner:  <a href="https://dsp.com/click?redirect=landing">  ← 하드코딩! 하나뿐!
         → SSP URL을 넣을 자리가 없음
```

핵심 차이:

| | Native | Video | Banner |
|--|--------|-------|--------|
| 클릭 트래커 | **배열** (여러 개) | **여러 태그** (여러 개) | **`<a href>` 하나** (1개) |
| 트래커 추가 | 배열에 push | 태그 추가 | **불가능** |
| 랜딩 분리 | `link.url` (별도) | `<ClickThrough>` (별도) | href에 **통합** |

```
근본 원인:
  Native/Video = "트래킹"과 "랜딩"이 분리된 구조
  Banner       = "트래킹"과 "랜딩"이 <a href> 하나에 합쳐진 비구조적 HTML
```

### 3.5 Banner 클릭 트래킹 해결책

#### 해결책 1: Click Macro (업계 표준, 가장 권장)

DSP가 adm HTML에 SSP 클릭 URL을 삽입할 수 있는 **매크로 자리**를 미리 만들어둔다.

```
단계:
1. SSP가 DSP에게 "우리 클릭 매크로는 ${CLICK_URL}이야" 가이드 제공
2. DSP가 adm에 매크로를 포함하여 응답
3. SSP가 매크로를 실제 URL로 치환
4. 치환된 HTML을 클라이언트에 전달
```

```html
<!-- DSP가 응답한 원본 adm -->
<a href="https://dsp.com/click?ssp_click=${CLICK_URL}&redirect=https://landing.com">
  <img src="https://cdn.com/banner.jpg"/>
</a>
```

```html
<!-- SSP가 ${CLICK_URL}을 치환한 결과 -->
<a href="https://dsp.com/click?ssp_click=https%3A%2F%2Fssp.com%2Fclick%3Fid%3D789&redirect=https://landing.com">
  <img src="https://cdn.com/banner.jpg"/>
</a>
```

```
클릭 시 이동 경로:
  유저 클릭
    → dsp.com/click (DSP 클릭 기록)
      → ssp.com/click?id=789 (SSP 클릭 기록)
        → landing.com (최종 랜딩)
```

| 장점 | 단점 |
|------|------|
| 업계 표준 | DSP가 매크로를 지원해야 함 |
| 정확한 클릭 집계 | DSP마다 매크로 형식이 다를 수 있음 |
| 서버 사이드 치환 (보안) | 연동 시 사전 협의 필요 |

**백엔드 구현:**
```go
func replaceClickMacro(adm string, sspClickURL string) string {
    // URL 인코딩 후 치환
    encoded := url.QueryEscape(sspClickURL)
    return strings.ReplaceAll(adm, "${CLICK_URL}", encoded)
}
```

#### 해결책 2: HTML Wrapping (DOM 개입)

SSP가 DSP의 HTML을 감싸서 클릭 이벤트를 가로챈다.

```html
<!-- SSP가 DSP의 adm을 wrapping -->
<div onclick="trackSSPClick()" style="position:relative;">

  <!-- DSP 원본 adm -->
  <a href="https://dsp.com/click?redirect=https://landing.com">
    <img src="https://cdn.com/banner.jpg"/>
  </a>

</div>

<script>
function trackSSPClick() {
  // SSP 클릭 트래커를 1x1 이미지로 호출
  var img = new Image();
  img.src = "https://ssp.com/click?id=789&t=" + Date.now();
}
</script>
```

| 장점 | 단점 |
|------|------|
| DSP 협조 불필요 | 정확도 낮음 (더블 카운팅 가능) |
| 모든 DSP에 적용 가능 | DOM 조작으로 광고 깨질 수 있음 |
| | 클릭 vs 스크롤 구분 어려움 |
| | 보안/정책 이슈 가능 |

#### 해결책 3: MRAID (모바일 앱 전용)

MRAID SDK 환경에서는 SDK 레벨에서 클릭을 감지할 수 있다.

```
MRAID 흐름:
1. 광고가 mraid.open(url) 호출
2. SDK가 이 호출을 intercept
3. SSP 클릭 트래커 호출
4. 원래 URL로 이동

SDK 코드 (의사코드):
  mraid.open = function(url) {
    trackSSPClick(url);     // SSP 트래킹
    originalOpen(url);       // 원래 동작
  }
```

| 장점 | 단점 |
|------|------|
| 정확한 클릭 집계 | 모바일 앱 전용 |
| DSP 협조 불필요 | MRAID 지원 광고만 가능 |
| SDK 레벨 제어 | 웹에서 사용 불가 |

#### 해결책 4: Redirect Wrapping

SSP가 `<a href>`의 URL 자체를 SSP 리다이렉트 URL로 감싼다.

```html
<!-- 원본 -->
<a href="https://dsp.com/click?redirect=https://landing.com">

<!-- SSP가 변환 -->
<a href="https://ssp.com/click?id=789&redirect=https%3A%2F%2Fdsp.com%2Fclick%3Fredirect%3Dhttps%3A%2F%2Flanding.com">
```

```
클릭 시 이동 경로:
  유저 클릭
    → ssp.com/click (SSP 클릭 기록)
      → dsp.com/click (DSP 클릭 기록)
        → landing.com (최종 랜딩)
```

| 장점 | 단점 |
|------|------|
| DSP 협조 불필요 | HTML 파싱/수정 필요 (adm 내 href 찾기) |
| 정확한 집계 | 리다이렉트 체인 길어짐 (레이턴시) |
| | 복잡한 HTML/JS에서 href 파싱 실패 가능 |
| | DSP 정책 위반 가능 (URL 변조) |

**백엔드 구현:**
```go
func wrapClickURL(adm string, sspClickURL string) string {
    // 정규식으로 <a href="..."> 찾기
    re := regexp.MustCompile(`href="([^"]+)"`)
    return re.ReplaceAllStringFunc(adm, func(match string) string {
        originalURL := re.FindStringSubmatch(match)[1]
        encoded := url.QueryEscape(originalURL)
        return fmt.Sprintf(`href="%s&redirect=%s"`, sspClickURL, encoded)
    })
}
```

### 3.6 Banner 클릭 트래킹 해결책 비교

| 방식 | 정확도 | DSP 협조 | 구현 난이도 | 권장도 |
|------|--------|---------|-----------|--------|
| **Click Macro** | 높음 | 필요 | 중 | **1순위 (표준)** |
| **Redirect Wrapping** | 높음 | 불필요 | 상 | 2순위 |
| **MRAID** | 높음 | 불필요 | 중 | 3순위 (앱 전용) |
| **HTML Wrapping** | 낮음 | 불필요 | 중 | 최후 수단 |

**권장 전략:**
```
1. 신규 DSP 연동 시 → Click Macro 방식 가이드 제공 (표준)
2. Click Macro 미지원 DSP → Redirect Wrapping 적용
3. 모바일 앱 환경 → MRAID 활용
4. 어떤 것도 안 되면 → HTML Wrapping (정확도 낮음 감수)
```

---

## 4. 전체 비교 정리

### 4.1 SSP 트래커 삽입 방법

```
┌─────────────────────────────────────────────────────────┐
│                 SSP 트래커 삽입 난이도                     │
├───────────┬──────────────────┬──────────────────────────┤
│           │ 노출 (Impression) │ 클릭 (Click)              │
├───────────┼──────────────────┼──────────────────────────┤
│ Native    │ ✅ 매우 쉬움      │ ✅ 매우 쉬움              │
│           │ imptrackers[]    │ clicktrackers[]          │
│           │ 에 URL 추가       │ 에 URL 추가              │
├───────────┼──────────────────┼──────────────────────────┤
│ Video     │ ✅ 쉬움           │ ✅ 쉬움                   │
│           │ <Impression>     │ <ClickTracking>          │
│           │ 태그 추가         │ 태그 추가                 │
├───────────┼──────────────────┼──────────────────────────┤
│ Banner    │ ✅ 쉬움           │ ❌ 어려움                 │
│           │ 1x1 <img>        │ <a href> 하드코딩         │
│           │ 태그 추가         │ Click Macro 등 필요       │
└───────────┴──────────────────┴──────────────────────────┘
```

### 4.2 왜 이런 차이가 생기는가?

```
설계 시기와 철학의 차이:

Banner (초기):
  "HTML을 통째로 줘. 브라우저가 알아서 렌더링해."
  → 비구조적. DSP가 HTML 전체를 통제. SSP 개입 여지 적음.

Video (VAST):
  "트래킹 포인트를 XML로 구조화하자."
  → 구조적. <Impression>, <ClickTracking> 등 표준 삽입 포인트 제공.

Native (최신):
  "데이터와 트래킹을 완전히 분리하자."
  → 가장 구조적. 배열 기반 트래커. 누구든 자유롭게 추가 가능.

진화 방향: 비구조적(Banner) → 반구조적(VAST) → 구조적(Native)
```

### 4.3 백엔드 처리 코드 (통합)

```go
func insertSSPTrackers(bid Bid, imp Imp, sspImpURL string, sspClickURL string) (string, error) {
    switch bid.MType {
    case 1: // Banner
        adm := bid.AdM
        // 노출: 1x1 픽셀 삽입 (쉬움)
        impPixel := fmt.Sprintf(`<img src="%s" width="1" height="1" style="display:none"/>`, sspImpURL)
        adm = adm + impPixel

        // 클릭: Click Macro 치환 (있으면)
        if strings.Contains(adm, "${CLICK_URL}") {
            adm = strings.ReplaceAll(adm, "${CLICK_URL}", url.QueryEscape(sspClickURL))
        }
        // Click Macro가 없으면 → Redirect Wrapping 또는 포기
        return adm, nil

    case 2: // Video (VAST)
        adm := bid.AdM
        // 노출: <Impression> 태그 추가
        impTag := fmt.Sprintf("<Impression><![CDATA[%s]]></Impression>", sspImpURL)
        adm = strings.Replace(adm, "<Impression>", impTag+"\n<Impression>", 1)

        // 클릭: <ClickTracking> 태그 추가
        clickTag := fmt.Sprintf("<ClickTracking><![CDATA[%s]]></ClickTracking>", sspClickURL)
        adm = strings.Replace(adm, "</VideoClicks>", clickTag+"\n</VideoClicks>", 1)
        return adm, nil

    case 4: // Native
        var native NativeResponse
        json.Unmarshal([]byte(bid.AdM), &native)

        // 노출: 배열에 추가
        native.ImpTrackers = append(native.ImpTrackers, sspImpURL)

        // 클릭: 배열에 추가
        native.Link.ClickTrackers = append(native.Link.ClickTrackers, sspClickURL)

        result, _ := json.Marshal(native)
        return string(result), nil

    default:
        return bid.AdM, fmt.Errorf("unknown mtype: %d", bid.MType)
    }
}
```

---

## 5. 요약

```
┌─────────────────────────────────────────────────────────────┐
│                    핵심 정리                                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Native:  트래킹이 JSON 배열 → 추가 자유로움 → 가장 편함     │
│  Video:   트래킹이 XML 태그 → 추가 가능 → 편함               │
│  Banner:  트래킹이 HTML에 하드코딩 → 추가 어려움 → 불편       │
│                                                             │
│  Banner 클릭 해결:                                           │
│    1순위: Click Macro (${CLICK_URL}) ← 업계 표준             │
│    2순위: Redirect Wrapping ← DSP 협조 불필요                │
│    3순위: MRAID ← 모바일 앱 전용                              │
│    최후: HTML Wrapping ← 정확도 낮음                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

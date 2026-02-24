---
layout: single
title: "OpenRTB adm 필드 상세 - 미디어 타입별 광고 마크업"
date: 2026-02-24 18:00:00 +0900
categories: [ad-tech, openrtb]
---

OpenRTB Bid Response에서 `seatbid[].bid[].adm` 필드는 광고 마크업(Ad Markup)을 담는 단일 문자열 필드다. 미디어 타입(배너, 네이티브, 비디오, 오디오)에 관계없이 동일한 필드를 사용하지만, 담기는 데이터의 형식이 다르다.

> **💡 Tip:** 경매에서 낙찰된 후, 구매자가 실제 물건을 보내줘야 하죠?
> adm이 바로 그 **실물**입니다.
>
> 광고 유형에 따라 실물의 형태가 다릅니다:
> - **배너 광고** → 포스터(HTML 코드)를 보냅니다. 웹페이지에 바로 붙일 수 있습니다.
> - **비디오 광고** → 영상 재생 레시피(VAST XML)를 보냅니다. "이 영상을 재생하고, 25%/50%/75%/100% 시점에 트래킹 URL을 호출하세요"라는 지시서입니다.
> - **네이티브 광고** → 조립 키트(JSON)를 보냅니다. 제목, 이미지, 설명, 버튼을 각각 보내서 앱이 자체 디자인에 맞게 조립합니다.
> - **오디오 광고** → 라디오 광고 레시피(DAAST XML)를 보냅니다.
>
> 중요: adm 필드는 **항상 문자열(string)**입니다.
> HTML이든, XML이든, JSON이든 모두 하나의 문자열 안에 들어갑니다.

---

## 미디어 타입별 adm 형식 요약

| mtype | 미디어 타입 | adm 형식 | 내용 |
|-------|-----------|---------|------|
| 1 | Banner | HTML String | 브라우저가 직접 렌더링하는 HTML 태그 |
| 2 | Video | XML String (VAST) | `<VAST>` 또는 `<?xml` 로 시작하는 VAST 문서 |
| 3 | Audio | XML String (DAAST) | `<DAAST>` 로 시작하는 DAAST 문서 |
| 4 | Native | JSON String | Stringify된 Native Response Object |

---

## 1. 배너 (Banner)

`adm` 필드에 HTML 문자열이 직접 포함된다. Publisher 측 렌더러가 이 HTML을 iframe 또는 div에 삽입하여 표시한다.

```json
{
  "id": "resp-123",
  "seatbid": [
    {
      "bid": [
        {
          "id": "bid-1",
          "impid": "imp-1",
          "price": 5.0,
          "adomain": ["advertiser.com"],
          "adm": "<a href='https://adserver.com/click'><img src='https://cdn.com/banner.jpg' width='300' height='250'></a>",
          "crid": "creative-123",
          "w": 300,
          "h": 250
        }
      ]
    }
  ]
}
```

---

## 2. 비디오 (Video / VAST)

`adm` 필드에 VAST(Video Ad Serving Template) XML 문서가 문자열로 포함된다. 클라이언트의 VAST 플레이어가 이를 파싱하여 영상을 재생한다.

```json
{
  "id": "resp-124",
  "seatbid": [
    {
      "bid": [
        {
          "id": "bid-2",
          "impid": "imp-2",
          "price": 8.0,
          "adomain": ["advertiser.com"],
          "adm": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><VAST version=\"4.0\"><Ad><InLine><AdSystem>DSP</AdSystem><AdTitle>Example Video Ad</AdTitle><Creatives><Creative><Linear><Duration>00:00:30</Duration><MediaFiles><MediaFile type=\"video/mp4\" width=\"1280\" height=\"720\">https://cdn.com/video.mp4</MediaFile></MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>",
          "crid": "creative-video-456"
        }
      ]
    }
  ]
}
```

---

## 3. 오디오 (Audio / DAAST)

`adm` 필드에 DAAST(Digital Audio Ad Serving Template) XML 문서가 문자열로 포함된다. DAAST는 VAST의 오디오 전용 파생 규격이다.

```json
{
  "id": "resp-125",
  "seatbid": [
    {
      "bid": [
        {
          "id": "bid-3",
          "impid": "imp-3",
          "price": 4.5,
          "adomain": ["advertiser.com"],
          "adm": "<DAAST version=\"1.0\"><Ad><InLine><AdSystem>DSP</AdSystem><AdTitle>Example Audio Ad</AdTitle><Creatives><Creative><Linear><Duration>00:00:15</Duration><MediaFiles><MediaFile type=\"audio/mpeg\">https://cdn.com/audio.mp3</MediaFile></MediaFiles></Linear></Creative></Creatives></InLine></Ad></DAAST>",
          "crid": "creative-audio-789"
        }
      ]
    }
  ]
}
```

---

## 4. 네이티브 (Native)

`adm` 필드에 Native Response Object를 JSON으로 직렬화(Stringify)한 문자열이 포함된다. 수신 측에서 이 문자열을 JSON으로 파싱하면 `assets` 배열이 나온다.

```json
{
  "id": "resp-126",
  "seatbid": [
    {
      "bid": [
        {
          "id": "bid-4",
          "impid": "imp-4",
          "price": 3.5,
          "adomain": ["advertiser.com"],
          "adm": "{\"native\":{\"link\":{\"url\":\"https://advertiser.com/landing\"},\"assets\":[{\"id\":1,\"title\":{\"text\":\"광고 제목\"}},{\"id\":2,\"img\":{\"url\":\"https://cdn.com/img.jpg\",\"w\":1200,\"h\":627}},{\"id\":3,\"data\":{\"value\":\"광고 설명 문구\"}}]}}",
          "crid": "native-creative-101"
        }
      ]
    }
  ]
}
```

`adm` 문자열을 파싱한 실제 구조:

```json
{
  "native": {
    "link": {
      "url": "https://advertiser.com/landing"
    },
    "assets": [
      {
        "id": 1,
        "title": { "text": "광고 제목" }
      },
      {
        "id": 2,
        "img": { "url": "https://cdn.com/img.jpg", "w": 1200, "h": 627 }
      },
      {
        "id": 3,
        "data": { "value": "광고 설명 문구" }
      }
    ]
  }
}
```

---

## adm 파싱 전략

수신한 `adm` 문자열의 미디어 타입을 런타임에 판별해야 하는 경우, 아래 순서로 감지할 수 있다. 단, `mtype` 필드가 명시된 경우에는 해당 값을 우선적으로 사용한다.

```
1. bid.mtype 필드 확인 (1=Banner, 2=Video, 3=Audio, 4=Native)
   → 명시된 경우 해당 형식으로 파싱

2. mtype 미지정 시 adm 내용 기반 감지:
   - "<VAST" 또는 "<?xml" 로 시작 → Video (VAST XML)
   - "<DAAST" 로 시작                → Audio (DAAST XML)
   - "{" 로 시작하고 "assets" 포함   → Native (JSON String)
   - 그 외                           → Banner (HTML String)
```

---

## 구현 시 주의사항

- **네이티브 adm은 반드시 Stringify** 해야 한다. JSON 객체를 직접 `adm` 값으로 설정하면 OpenRTB 스키마 위반이다.
- **비디오/오디오 adm의 XML 이스케이프**: JSON 문자열 안에 XML을 포함하므로 따옴표(`"`)는 `\"` 로 이스케이프된다.
- **mtype 필드 명시 권고**: OpenRTB 2.6에서는 `bid.mtype`으로 미디어 타입을 명시적으로 선언하도록 권고한다. 파싱 의존성을 줄일 수 있다.
- **adm 부재 시**: `adm`이 없고 `nurl`만 있는 경우, SSP가 `nurl`을 호출하면 DSP가 응답 본문으로 `adm`을 반환한다(Proxy 방식). 자세한 내용은 OpenRTB - NURL 참고.

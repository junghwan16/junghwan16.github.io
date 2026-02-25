---
title: "User Agent Client Hints에 대해 알아보자"
date: 2026-02-07 14:00:00 +0900
categories: [frontend, web]
---

## 왜 필요한가?

기존 `User-Agent` 문자열:

```
Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.6312.58 Safari/537.36
```

1. **프라이버시** - OS 버전, CPU, 브라우저 정확한 버전이 매 요청마다 노출되어 fingerprinting에 쓰인다.
2. **파싱의 고통** - `Mozilla/5.0`, `KHTML, like Gecko` 등 의미 없는 레거시 토큰이 가득하다.

Chrome은 이 문자열을 점진적으로 축소(User-Agent Reduction)하고, 대신 **User-Agent Client Hints(UA-CH)** 를 도입했다.

> 서버가 **필요한 정보만 명시적으로 요청**하고, 브라우저가 **허락한 정보만 응답**한다.

---

## Low-Entropy vs High-Entropy

### Low-Entropy (자동 제공)

별도 요청 없이 항상 접근 가능. Chrome 89부터 매 요청에 자동 포함된다.

| HTTP 헤더            | JS 필드    | 설명                   | 예시                      |
| -------------------- | ---------- | ---------------------- | ------------------------- |
| `Sec-CH-UA`          | `brands`   | 브라우저 + 메이저 버전 | `"Google Chrome";v="123"` |
| `Sec-CH-UA-Mobile`   | `mobile`   | 모바일 여부            | `?0`                      |
| `Sec-CH-UA-Platform` | `platform` | OS 이름                | `"macOS"`                 |

> `Sec-` 접두사는 JavaScript로 위조할 수 없는 forbidden header임을 의미한다.

Console에서 확인:

```javascript
console.log(navigator.userAgentData);
// { brands: [{brand: "Google Chrome", version: "123"}, ...], mobile: false, platform: "macOS" }
```

`brands`에 `"Not:A-Brand"` 같은 항목이 섞여 있는 이유는, 기존 UA 파싱 코드가 이 값을 그대로 파싱하지 못하도록 의도적으로 넣은 GREASE 메커니즘이다.

### High-Entropy (요청 필요)

명시적으로 요청해야 받을 수 있다. 브라우저가 **거부할 수도 있다**.

| HTTP 헤더                     | JS 필드           | 설명                        | 예시              |
| ----------------------------- | ----------------- | --------------------------- | ----------------- |
| `Sec-CH-UA-Full-Version-List` | `fullVersionList` | 브라우저 정확한 버전        | `"123.0.6312.58"` |
| `Sec-CH-UA-Platform-Version`  | `platformVersion` | OS 버전                     | `"14.4.0"`        |
| `Sec-CH-UA-Arch`              | `architecture`    | CPU 아키텍처                | `"arm"`           |
| `Sec-CH-UA-Bitness`           | `bitness`         | 32/64비트                   | `"64"`            |
| `Sec-CH-UA-Model`             | `model`           | 기기 모델                   | `"Pixel 7"`       |
| `Sec-CH-UA-WoW64`             | `wow64`           | 64비트 OS + 32비트 브라우저 | `false`           |
| `Sec-CH-UA-Form-Factors`      | `formFactors`     | 폼 팩터                     | `["Tablet"]`      |

Console에서 확인 (`getHighEntropyValues()`는 Promise를 반환한다):

```javascript
const ua = await navigator.userAgentData.getHighEntropyValues([
  "architecture",
  "bitness",
  "model",
  "platformVersion",
  "fullVersionList",
]);
console.log(ua);
```

---

## 서버에서 High-Entropy 요청하기

### Accept-CH 헤더

```http
HTTP/1.1 200 OK
Accept-CH: Sec-CH-UA-Full-Version-List, Sec-CH-UA-Platform-Version, Sec-CH-UA-Arch
```

`Accept-CH`는 첫 번째 응답에 포함되므로, 추가 힌트는 **두 번째 요청부터** 전송된다.

### Critical-CH (첫 요청부터 받기)

```http
HTTP/1.1 200 OK
Accept-CH: Sec-CH-UA-Arch, Sec-CH-UA-Bitness
Critical-CH: Sec-CH-UA-Arch, Sec-CH-UA-Bitness
```

`Critical-CH`에 명시된 헤더가 원래 요청에 없었다면, 브라우저가 해당 헤더를 포함하여 **요청을 자동 재전송**한다.

### meta 태그

서버 설정을 변경할 수 없는 경우:

```html
<meta
  http-equiv="Accept-CH"
  content="Sec-CH-UA-Full-Version-List, Sec-CH-UA-Platform-Version"
/>
```

단, meta 태그 힌트는 **해당 페이지의 하위 리소스 요청**에만 적용된다. 페이지 내비게이션에는 적용되지 않는다.

---

## Cross-Origin 요청에서의 Client Hints

기본적으로 Client Hints는 **same-origin** 요청에만 전송된다. 다른 출처에도 전송하려면 `Permissions-Policy`를 설정해야 한다.

```http
Accept-CH: Sec-CH-UA-Platform-Version
Permissions-Policy: ch-ua-platform-version=(self "https://cdn.example.com")
```

디렉티브 이름 규칙: `Sec-CH-UA-Platform-Version` -> `ch-ua-platform-version` (소문자 변환)

---

## 활용 예시: Windows 버전 구분

기존 UA 문자열에서는 Windows 10과 11 모두 `Windows NT 10.0`으로 표시되어 구분이 불가능했다. UA-CH의 `platformVersion`으로 구분할 수 있다.

```javascript
const ua = await navigator.userAgentData.getHighEntropyValues([
  "platformVersion",
]);
const major = parseInt(ua.platformVersion.split(".")[0]);

if (ua.platform === "Windows") {
  if (major >= 13) console.log("Windows 11 이상");
  else if (major > 0)
    console.log("Windows 10"); // 1~12는 Windows 10
  else console.log("Windows 10 이전"); // 0은 Windows 10 이전
}
```

---

## Prebid.js는 Client Hints를 어떻게 처리할까?

광고 네트워크는 기기 타겟팅, 부정 트래픽 탐지를 위해 UA 정보에 의존한다. User-Agent 축소에 대응하여 OpenRTB 2.6은 **`device.sua`** (Structured User Agent)를 도입했고, Prebid.js가 이를 구현한다.

### OpenRTB 2.6의 device.sua

```json
{
  "device": {
    "ua": "Mozilla/5.0 ...",
    "sua": {
      "browsers": [
        { "brand": "Google Chrome", "version": ["123", "0", "6312", "58"] },
        { "brand": "Chromium", "version": ["123", "0", "6312", "58"] }
      ],
      "platform": { "brand": "macOS", "version": ["14", "4"] },
      "mobile": 0,
      "architecture": "arm",
      "bitness": "64",
      "model": "",
      "source": 2
    }
  }
}
```

UA-CH와 SUA 필드 매핑:

| SUA 필드           | UA-CH 소스                    | 설명                          |
| ------------------ | ----------------------------- | ----------------------------- |
| `browsers`         | `Sec-CH-UA-Full-Version-List` | 브라우저 브랜드 + 정확한 버전 |
| `platform.brand`   | `Sec-CH-UA-Platform`          | OS 이름                       |
| `platform.version` | `Sec-CH-UA-Platform-Version`  | OS 버전                       |
| `mobile`           | `Sec-CH-UA-Mobile`            | 모바일 여부 (0 또는 1)        |
| `architecture`     | `Sec-CH-UA-Arch`              | CPU 아키텍처                  |
| `bitness`          | `Sec-CH-UA-Bitness`           | 32/64비트                     |
| `model`            | `Sec-CH-UA-Model`             | 기기 모델명                   |
| `source`           | -                             | 데이터 출처 (아래 참고)       |

`source` 값: `0` 알 수 없음 / `1` low-entropy만 사용 / `2` high-entropy 사용 / `3` UA 문자열 파싱

> 스펙 권장사항: `sua`가 존재하면 비더는 `ua`(문자열) 대신 **`sua`를 우선 사용**해야 한다.

### Prebid.js 설정

퍼블리셔가 할 일은 `uaHints` 설정 하나뿐이다.

```javascript
pbjs.setConfig({
  firstPartyData: {
    uaHints: [
      "architecture",
      "model",
      "platform",
      "platformVersion",
      "fullVersionList",
    ],
  },
});
```

Prebid.js가 내부적으로 `getHighEntropyValues()`를 호출하고, `device.sua` 형식으로 변환하여 모든 비더에게 전달한다. `uaHints`를 설정하지 않으면 low-entropy만 수집된다.

Prebid.js는 **클라이언트 JS에서 직접 수집**하여 입찰 요청 본문에 넣으므로, `Accept-CH`나 `Delegate-CH` 서버 헤더 설정이 필요 없다.

### 비더 어댑터에서 sua 읽기

```javascript
buildRequests: function(validBidRequests, bidderRequest) {
  const sua = bidderRequest.ortb2.device?.sua;
  return {
    method: "POST",
    url: ENDPOINT,
    data: { device: { ua: bidderRequest.ortb2.device?.ua, sua } },
  };
};
```

---

## 브라우저 지원 현황

| 브라우저         | 지원 |
| ---------------- | ---- |
| Chrome 89+       | O    |
| Edge 89+         | O    |
| Opera 75+        | O    |
| Samsung Internet | O    |
| Firefox          | X    |
| Safari           | X    |

Firefox와 Safari는 UA 문자열을 축소하는 자체 방식을 택했지만, UA-CH 같은 대체 API는 제공하지 않고 있다.

---

## 핵심 요약

1. **HTTPS 필수** - Client Hints는 보안 연결에서만 동작한다.
2. **Low-entropy는 자동** - `brands`, `mobile`, `platform`은 매 요청에 자동 포함된다.
3. **High-entropy는 요청 필요** - 서버는 `Accept-CH`, 클라이언트는 `getHighEntropyValues()`로 요청한다.
4. **브라우저가 거부할 수 있다** - 기존 User-Agent와 달리 브라우저가 정보 제공을 거부할 수 있다.
5. **Chromium 전용** - 현재 Firefox, Safari는 미지원이다.

---

## 참고자료

- [Naver D2 - User-Agent Client Hints](https://d2.naver.com/helloworld/6532276) — UA-CH 도입 배경과 동작 원리에 대한 한국어 해설
- [Chrome for Developers - User-Agent Client Hints](https://developer.chrome.com/docs/privacy-security/user-agent-client-hints) — Chrome 공식 UA-CH 가이드
- [MDN - User-Agent Client Hints API](https://developer.mozilla.org/en-US/docs/Web/API/User-Agent_Client_Hints_API) — Web API 레퍼런스
